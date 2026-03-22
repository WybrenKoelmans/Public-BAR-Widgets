import * as fs from "node:fs";
import * as path from "node:path";
import { glob } from "glob";
import archiver from "archiver";
import sharp from "sharp";

const ROOT_DIR = path.resolve("/app");
const BUILD_DIR = path.join(ROOT_DIR, "build");
const WIDGETS_DIR = path.join(ROOT_DIR, "Widgets");
const DIST_DIR = path.join(BUILD_DIR, "distributions");
const SITES_DIR = path.join(BUILD_DIR, "sites");

interface Manifest {
  id: string;
  last_updated?: string;
  [key: string]: unknown;
}

interface WidgetInfo {
  widgetDir: string;
  widgetName: string;
  manifest: Manifest | Manifest[];
  lastUpdated: number;
}

function findFile(dir: string, name: string, maxDepth: number): string | null {
  const queue: { path: string; depth: number }[] = [{ path: dir, depth: 0 }];
  while (queue.length > 0) {
    const current = queue.shift()!;
    const filePath = path.join(current.path, name);
    if (fs.existsSync(filePath)) return filePath;
    if (current.depth < maxDepth) {
      const entries = fs.readdirSync(current.path, { withFileTypes: true });
      for (const entry of entries) {
        if (entry.isDirectory()) {
          queue.push({
            path: path.join(current.path, entry.name),
            depth: current.depth + 1,
          });
        }
      }
    }
  }
  return null;
}

function createZip(sourceDir: string, outputPath: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const output = fs.createWriteStream(outputPath);
    const archive = archiver("zip", { zlib: { level: 9 } });
    output.on("close", resolve);
    archive.on("error", reject);
    archive.pipe(output);
    archive.directory(sourceDir, false);
    archive.finalize();
  });
}

async function main() {
  // Clean build directory contents (can't remove the mount point itself)
  if (fs.existsSync(BUILD_DIR)) {
    for (const entry of fs.readdirSync(BUILD_DIR)) {
      fs.rmSync(path.join(BUILD_DIR, entry), { recursive: true, force: true });
    }
  }
  fs.mkdirSync(DIST_DIR, { recursive: true });
  fs.mkdirSync(SITES_DIR, { recursive: true });

  // Find all manifest.json files
  const manifestPaths = await glob("**/manifest.json", {
    cwd: WIDGETS_DIR,
    absolute: true,
  });

  // Collect widget info and check for duplicates
  const processedWidgets = new Set<string>();
  const widgets: WidgetInfo[] = [];

  for (const manifestPath of manifestPaths) {
    const widgetDir = path.dirname(manifestPath);
    const widgetName = path.basename(widgetDir);

    if (processedWidgets.has(widgetName)) {
      console.error(
        `ERROR: Duplicate widget_name '${widgetName}' found. Exiting.`
      );
      process.exit(1);
    }
    processedWidgets.add(widgetName);

    const manifest: Manifest | Manifest[] = JSON.parse(
      fs.readFileSync(manifestPath, "utf-8")
    );
    const firstManifest = Array.isArray(manifest) ? manifest[0] : manifest;
    const lastUpdated = firstManifest?.last_updated
      ? new Date(firstManifest.last_updated).getTime()
      : 0;

    widgets.push({ widgetDir, widgetName, manifest, lastUpdated });
  }

  // Sort by last_updated (most recent first)
  widgets.sort((a, b) => b.lastUpdated - a.lastUpdated);

  console.log("Widget order (by last_updated):");
  for (const w of widgets) {
    const date = w.lastUpdated
      ? new Date(w.lastUpdated).toISOString()
      : "unknown";
    console.log(`  ${w.widgetName}: ${date}`);
  }

  // Write merged manifests.json ordered by commit date
  const manifests = widgets.flatMap((w) =>
    Array.isArray(w.manifest) ? w.manifest : [w.manifest]
  );
  fs.writeFileSync(
    path.join(BUILD_DIR, "manifests.json"),
    JSON.stringify(manifests, null, 2)
  );

  // Process each widget
  for (const { widgetDir, widgetName } of widgets) {
    console.log(`Processing ${widgetName}...`);

    // Create zip distribution
    await createZip(widgetDir, path.join(DIST_DIR, `${widgetName}.zip`));

    // Create site data
    const siteDir = path.join(SITES_DIR, widgetName);
    fs.mkdirSync(siteDir, { recursive: true });

    // Find and process cover image
    const coverImage = findFile(widgetDir, "cover.png", 2);
    if (!coverImage) {
      console.error(`  - ERROR: No cover.png found for ${widgetName}`);
      process.exit(1);
    }

    console.log("  - Converting cover image...");
    await sharp(coverImage)
      .resize(460, 300, { fit: "cover", position: "center" })
      .toFile(path.join(siteDir, `${widgetName}_460x300.png`));
    await sharp(coverImage)
      .resize(325, 100, { fit: "cover", position: "center" })
      .toFile(path.join(siteDir, `${widgetName}_325x100.png`));

    // Find and copy README
    const readmeFile = findFile(widgetDir, "README.md", 2);
    if (!readmeFile) {
      console.error(`  - ERROR: No README.md found for ${widgetName}`);
      process.exit(1);
    }

    console.log("  - Copying README.md...");
    fs.copyFileSync(readmeFile, path.join(siteDir, `${widgetName}.md`));
  }

  console.log("Build process completed.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
