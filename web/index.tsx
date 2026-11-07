import React, { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "./styles.css";
import App from "./App";
import { FinesClerk } from "./components/FinesClerk";

const root = createRoot(document.getElementById("root")!);
root.render(
  <StrictMode>
    <App />
    <FinesClerk />
  </StrictMode>
);