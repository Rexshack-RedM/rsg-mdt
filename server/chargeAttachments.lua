local RSGCore = exports['rsg-core']:GetCoreObject()

local AttachmentsDatabaseReady = false

local function initializeAttachmentsDatabase()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS mdt_charge_attachments (
            id INT AUTO_INCREMENT PRIMARY KEY,
            charge_id INT NOT NULL,
            report_id INT NOT NULL,
            attached_by VARCHAR(50) NOT NULL,
            attached_by_name VARCHAR(100) NOT NULL,
            attached_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE KEY unique_charge_report (charge_id, report_id),
            INDEX idx_charge_id (charge_id),
            INDEX idx_report_id (report_id),
            FOREIGN KEY (charge_id) REFERENCES mdt_issued_charges(id) ON DELETE CASCADE,
            FOREIGN KEY (report_id) REFERENCES mdt_reports(id) ON DELETE CASCADE
        )
    ]])

    AttachmentsDatabaseReady = true
end

CreateThread(function()
    Wait(2000)
    initializeAttachmentsDatabase()
end)

local function waitForAttachmentsDatabase()
    local timeout = 5000
    local waited = 0
    while not AttachmentsDatabaseReady and waited < timeout do
        Wait(100)
        waited = waited + 100
    end
    return AttachmentsDatabaseReady
end

local function hasCreateRecordsPermission(source)
    local player = RSGCore.Functions.GetPlayer(source)
    if not player then return false end
    
    local job = player.PlayerData.job
    if not job then return false end
    
    local jobConfig = Config.LawJobs[job.name]
    if not jobConfig then return false end
    
    local gradeConfig = jobConfig.grades[job.grade.level]
    if not gradeConfig then return false end
    
    return gradeConfig.canCreateRecords == true
end

local function logAttachmentAction(source, action, chargeId, reportId, details)
    local player = RSGCore.Functions.GetPlayer(source)
    if not player then return end
    
    local performerName = player.PlayerData.charinfo.firstname .. ' ' .. player.PlayerData.charinfo.lastname
    local performerCid = player.PlayerData.citizenid
    
    MySQL.insert.await(
        "INSERT INTO mdt_audit_logs (action, target_type, target_id, target_name, details, performed_by, performed_by_name) VALUES (?, ?, ?, ?, ?, ?, ?)",
        { action, 'charge_attachment', tostring(chargeId), 'Charge #' .. chargeId .. ' - Report #' .. reportId, details and json.encode(details) or nil, performerCid, performerName }
    )
end

lib.callback.register('rsg-mdt:server:getAvailableReportsForAttachment', function(source, searchQuery)
    if not waitForAttachmentsDatabase() then return {} end
    if not hasCreateRecordsPermission(source) then return {} end
    
    local query
    local params
    
    if searchQuery and #searchQuery > 0 then
        query = [[
            SELECT id, title, type, officer, created_at
            FROM mdt_reports
            WHERE title LIKE ? OR officer LIKE ? OR type LIKE ?
            ORDER BY created_at DESC
            LIMIT 50
        ]]
        local searchPattern = '%' .. searchQuery .. '%'
        params = { searchPattern, searchPattern, searchPattern }
    else
        query = [[
            SELECT id, title, type, officer, created_at
            FROM mdt_reports
            ORDER BY created_at DESC
            LIMIT 50
        ]]
        params = {}
    end
    
    local reports = MySQL.query.await(query, params)
    return reports or {}
end)

lib.callback.register('rsg-mdt:server:attachReportsToCharge', function(source, data)
    if not waitForAttachmentsDatabase() then
        return { success = false, message = 'Database not ready' }
    end
    if not hasCreateRecordsPermission(source) then
        return { success = false, message = 'You do not have permission to attach reports' }
    end
    
    local chargeId = tonumber(data.chargeId)
    local reportIds = data.reportIds
    
    if not chargeId or not reportIds or #reportIds == 0 then
        return { success = false, message = 'Charge ID and at least one report ID are required' }
    end
    
    local charge = MySQL.query.await("SELECT id FROM mdt_issued_charges WHERE id = ?", { chargeId })
    if not charge or not charge[1] then
        return { success = false, message = 'Charge not found' }
    end
    
    local player = RSGCore.Functions.GetPlayer(source)
    if not player then
        return { success = false, message = 'Player not found' }
    end
    
    local attachedBy = player.PlayerData.citizenid
    local attachedByName = player.PlayerData.charinfo.firstname .. ' ' .. player.PlayerData.charinfo.lastname
    
    local attachedCount = 0
    local alreadyAttached = 0
    local notFound = 0
    
    for _, reportId in ipairs(reportIds) do
        reportId = tonumber(reportId)
        if reportId then
            local report = MySQL.query.await("SELECT id FROM mdt_reports WHERE id = ?", { reportId })
            if report and report[1] then
                local existing = MySQL.query.await(
                    "SELECT id FROM mdt_charge_attachments WHERE charge_id = ? AND report_id = ?",
                    { chargeId, reportId }
                )
                
                if not existing or not existing[1] then
                    local insertId = MySQL.insert.await(
                        "INSERT INTO mdt_charge_attachments (charge_id, report_id, attached_by, attached_by_name) VALUES (?, ?, ?, ?)",
                        { chargeId, reportId, attachedBy, attachedByName }
                    )
                    
                    if insertId then
                        attachedCount = attachedCount + 1
                        logAttachmentAction(source, 'report_attached', chargeId, reportId, {
                            attachedBy = attachedByName
                        })
                    end
                else
                    alreadyAttached = alreadyAttached + 1
                end
            else
                notFound = notFound + 1
            end
        end
    end
    
    local message
    if attachedCount > 0 then
        message = attachedCount .. ' report(s) attached successfully'
        if alreadyAttached > 0 then
            message = message .. ', ' .. alreadyAttached .. ' already attached'
        end
        if notFound > 0 then
            message = message .. ', ' .. notFound .. ' not found'
        end
    elseif alreadyAttached > 0 then
        message = 'All selected reports are already attached'
    else
        message = 'No reports could be attached'
    end
    
    return {
        success = attachedCount > 0,
        message = message,
        attachedCount = attachedCount,
        alreadyAttached = alreadyAttached,
        notFound = notFound
    }
end)

lib.callback.register('rsg-mdt:server:removeAttachmentFromCharge', function(source, data)
    if not waitForAttachmentsDatabase() then
        return { success = false, message = 'Database not ready' }
    end
    if not hasCreateRecordsPermission(source) then
        return { success = false, message = 'You do not have permission to remove attachments' }
    end
    
    local chargeId = tonumber(data.chargeId)
    local reportId = tonumber(data.reportId)
    
    if not chargeId or not reportId then
        return { success = false, message = 'Charge ID and Report ID are required' }
    end
    
    local affected = MySQL.update.await(
        "DELETE FROM mdt_charge_attachments WHERE charge_id = ? AND report_id = ?",
        { chargeId, reportId }
    )
    
    if affected and affected > 0 then
        logAttachmentAction(source, 'report_detached', chargeId, reportId)
        return { success = true, message = 'Report detached from charge' }
    end
    
    return { success = false, message = 'Attachment not found' }
end)

lib.callback.register('rsg-mdt:server:getChargeAttachments', function(source, chargeId)
    if not waitForAttachmentsDatabase() then return {} end
    
    chargeId = tonumber(chargeId)
    if not chargeId then return {} end
    
    local attachments = MySQL.query.await([[
        SELECT 
            ca.id as attachment_id,
            ca.charge_id,
            ca.report_id,
            ca.attached_by,
            ca.attached_by_name,
            ca.attached_at,
            r.title as report_title,
            r.type as report_type,
            r.officer as report_officer,
            r.created_at as report_created_at
        FROM mdt_charge_attachments ca
        INNER JOIN mdt_reports r ON ca.report_id = r.id
        WHERE ca.charge_id = ?
        ORDER BY ca.attached_at DESC
    ]], { chargeId })
    
    return attachments or {}
end)

lib.callback.register('rsg-mdt:server:getReportsWithCharges', function(source, reportId)
    if not waitForAttachmentsDatabase() then return {} end
    
    reportId = tonumber(reportId)
    if not reportId then return {} end
    
    local charges = MySQL.query.await([[
        SELECT 
            ca.id as attachment_id,
            ca.charge_id,
            ca.report_id,
            ca.attached_at,
            ic.charge_name,
            ic.citizen_name,
            ic.fine,
            ic.jailtime,
            ic.officer
        FROM mdt_charge_attachments ca
        INNER JOIN mdt_issued_charges ic ON ca.charge_id = ic.id
        WHERE ca.report_id = ?
        ORDER BY ca.attached_at DESC
    ]], { reportId })
    
    return charges or {}
end)

exports('getChargeAttachments', function(chargeId)
    if not waitForAttachmentsDatabase() then return {} end
    
    chargeId = tonumber(chargeId)
    if not chargeId then return {} end
    
    return MySQL.query.await([[
        SELECT 
            ca.*,
            r.title as report_title,
            r.type as report_type
        FROM mdt_charge_attachments ca
        INNER JOIN mdt_reports r ON ca.report_id = r.id
        WHERE ca.charge_id = ?
        ORDER BY ca.attached_at DESC
    ]], { chargeId }) or {}
end)

exports('getReportsWithCharges', function(reportId)
    if not waitForAttachmentsDatabase() then return {} end
    
    reportId = tonumber(reportId)
    if not reportId then return {} end
    
    return MySQL.query.await([[
        SELECT 
            ca.*,
            ic.charge_name,
            ic.citizen_name,
            ic.fine,
            ic.jailtime
        FROM mdt_charge_attachments ca
        INNER JOIN mdt_issued_charges ic ON ca.charge_id = ic.id
        WHERE ca.report_id = ?
        ORDER BY ca.attached_at DESC
    ]], { reportId }) or {}
end)
