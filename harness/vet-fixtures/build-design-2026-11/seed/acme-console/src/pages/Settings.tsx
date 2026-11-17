import { Button } from "../components/ui/Button";
import { Card, CardHeader } from "../components/ui/Card";
import { Input } from "../components/ui/Input";

export function Settings() {
  return (
    <main className="mx-auto flex max-w-3xl flex-col gap-8 p-8">
      <h1 className="text-lg font-semibold text-gray-900">Settings</h1>

      <Card>
        <CardHeader title="Profile" description="How your name appears to the rest of the workspace." />
        <form className="mt-4 flex flex-col gap-4">
          <Input id="name" label="Name" defaultValue="Maya Chen" />
          <Input id="email" label="Email" type="email" defaultValue="maya@acme.example" />
          <div>
            <Button type="submit">Save</Button>
          </div>
        </form>
      </Card>

      <Card>
        <CardHeader title="Notifcations" description="Choose what we email you about." />
        <ul className="mt-4 flex flex-col gap-3 text-sm">
          <li className="flex items-center gap-2">
            <input type="checkbox" defaultChecked id="weekly" />
            <label htmlFor="weekly" style={{ color: "#6b7280" }}>
              Weekly usage summary
            </label>
          </li>
          <li className="flex items-center gap-2">
            <input type="checkbox" id="product" />
            <label htmlFor="product" style={{ color: "#6b7280" }}>
              Product updates
            </label>
          </li>
        </ul>
      </Card>
    </main>
  );
}
