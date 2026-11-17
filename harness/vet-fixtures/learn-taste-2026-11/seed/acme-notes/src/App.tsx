import { useState } from "react";
import { Archive } from "./pages/Archive";

type Page = "dashboard" | "archive" | "settings";

export function App() {
  const [page, setPage] = useState<Page>("dashboard");
  return (
    <div className="min-h-screen">
      <nav className="flex gap-4 px-6 py-3 text-sm text-fg-muted">
        <button type="button" onClick={() => setPage("dashboard")}>Notes</button>
        <button type="button" onClick={() => setPage("archive")}>Archive</button>
        <button type="button" onClick={() => setPage("settings")}>Settings</button>
      </nav>
      {page === "archive" && <Archive />}
    </div>
  );
}
