import { useState, type FormEvent } from "react";
import { Button } from "./Button";

export function NoteEditor({ onSave }: { onSave: (title: string, body: string) => void }) {
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");

  function submit(e: FormEvent) {
    e.preventDefault();
    onSave(title, body);
  }

  return (
    <form onSubmit={submit} className="flex flex-col gap-3">
      <input value={title} onChange={(e) => setTitle(e.target.value)} className="rounded-md bg-surface px-3 py-2 text-fg" />
      <textarea value={body} onChange={(e) => setBody(e.target.value)} className="min-h-40 rounded-md bg-surface px-3 py-2 text-fg" />
      <Button type="button">Save</Button>
    </form>
  );
}
