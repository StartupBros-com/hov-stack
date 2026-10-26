import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

// The package is dogfooded from a local checkout under ~/SITES; override with PI_BACKGROUND_SERVICES_ROOT.
const root = process.env.PI_BACKGROUND_SERVICES_ROOT || join(homedir(), "SITES", "pi-background-services");
const loaded = await import(pathToFileURL(join(root, "extensions", "index.ts")).href);

export default loaded.default;
