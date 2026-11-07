import { useState, useEffect, useCallback } from 'react';
import { useNuiEvent, fetchNui, isDebug } from '../hooks/useNui';

interface ClerkFine {
  id: number;
  amount: number;
  timeLeft: string;
  overdue: boolean;
}

interface ClerkData {
  title: string;
  fines: ClerkFine[];
  total: number;
  labels: Record<string, string>;
}

type Confirm = { kind: 'one'; fine: ClerkFine } | { kind: 'all' } | null;

const fmt = (s: string, ...args: (string | number)[]) => {
  let i = 0;
  return (s || '').replace(/%[sd]/g, () => String(args[i++] ?? ''));
};

const mock: ClerkData = {
  title: 'Court Clerk - Unpaid Fines',
  total: 75,
  fines: [
    { id: 12, amount: 50, timeLeft: '2 days, 3 hours', overdue: false },
    { id: 14, amount: 25, timeLeft: 'OVERDUE', overdue: true },
  ],
  labels: {},
};

export function FinesClerk() {
  const [data, setData] = useState<ClerkData | null>(isDebug ? null : null);
  const [confirm, setConfirm] = useState<Confirm>(null);
  const [busy, setBusy] = useState(false);

  useNuiEvent<ClerkData>('openFinesClerk', (d) => { setConfirm(null); setBusy(false); setData(d); });
  useNuiEvent<ClerkData>('updateFinesClerk', (d) => setData((prev) => (prev ? { ...prev, ...d } : prev)));
  useNuiEvent('closeFinesClerk', () => { setData(null); setConfirm(null); });

  const L = (k: string, fb: string) => data?.labels?.[k] || fb;

  const close = useCallback(() => {
    setData(null);
    setConfirm(null);
    fetchNui('finesClerkClose', {}, { success: true });
  }, []);

  useEffect(() => {
    if (!data) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') { if (confirm) setConfirm(null); else close(); }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [data, confirm, close]);

  // dev preview: window.dispatchEvent(new MessageEvent('message',{data:{action:'openFinesClerk',data:...}}))
  useEffect(() => { if (isDebug && location.hash === '#clerk') setData(mock); }, []);

  const doConfirm = async () => {
    if (!confirm || busy) return;
    setBusy(true);
    if (confirm.kind === 'one') {
      await fetchNui('finesClerkPay', { fineId: confirm.fine.id }, { success: true });
    } else {
      await fetchNui('finesClerkPayAll', {}, { success: true });
    }
    setBusy(false);
    setConfirm(null);
  };

  if (!data) return null;

  return (
    <div className="fc-root">
      <div className="fc-panel">
        <div className="fc-header">
          <span className="fc-icon-spacer" />
          <div className="fc-head-text">
            <div className="fc-title">{L('fines_title', 'Fine Payment')}</div>
            <div className="fc-sub">{data.title}</div>
          </div>
          <button className="fc-circle" onClick={close} aria-label="close">✕</button>
        </div>
        <div className="fc-divider"><span>✦</span></div>

        <div className="fc-list">
          {data.fines.length === 0 && (
            <div className="fc-empty">{L('notification_no_unpaid_fines_clear', 'You have no unpaid fines.')}</div>
          )}
          {data.fines.map((f) => (
            <button key={f.id} className="fc-row" disabled={busy} onClick={() => setConfirm({ kind: 'one', fine: f })}>
              <span className="fc-badge-icon">{f.overdue ? '!' : '$'}</span>
              <span className="fc-row-text">
                <span className="fc-row-title">{fmt(L('fines_fine_label', 'Fine #%s'), f.id)}</span>
                <span className="fc-row-desc">{fmt(L('fines_fine_detail', 'Amount: $%d | Time Left: %s'), f.amount, f.timeLeft)}</span>
              </span>
              {f.overdue && <span className="fc-pill fc-pill-bad">{L('fines_overdue', 'OVERDUE')}</span>}
            </button>
          ))}
        </div>

        {data.fines.length > 0 && (
          <>
            <div className="fc-divider"><span>✦</span></div>
            <div className="fc-footer">
              <span className="fc-total">{fmt(L('fines_pay_all_total', 'Total: $%d'), data.total)}</span>
              <button className="fc-btn" disabled={busy} onClick={() => setConfirm({ kind: 'all' })}>
                {L('fines_pay_all_title', 'Pay All Fines')}
              </button>
            </div>
          </>
        )}
      </div>

      {confirm && (
        <div className="fc-modal-wrap">
          <div className="fc-modal">
            <div className="fc-modal-title">
              {confirm.kind === 'one' ? L('fines_pay_header', 'Pay Fine') : L('fines_pay_all_title', 'Pay All Fines')}
            </div>
            <div className="fc-ink" />
            <div className="fc-modal-body">
              {confirm.kind === 'one'
                ? fmt(L('fines_pay_content', 'Pay fine #%d?\n\nAmount: $%d'), confirm.fine.id, confirm.fine.amount)
                : fmt(L('fines_pay_all_content', 'Pay all %d fine(s)?\n\nTotal Amount: $%d'), data.fines.length, data.total)}
            </div>
            <div className="fc-actions">
              <button className="fc-btn" disabled={busy} onClick={doConfirm}>
                {confirm.kind === 'one' ? L('fines_pay_confirm', 'Pay') : L('fines_pay_all_confirm', 'Pay All')}
              </button>
              <button className="fc-btn fc-btn-muted" disabled={busy} onClick={() => setConfirm(null)}>
                {L('fines_cancel', 'Cancel')}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
