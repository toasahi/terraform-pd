/**
 * Bundles src/index.ts into dist/index.mjs (ESM, Node.js 24) and packages dist/lambda.zip for the
 * nodejs24.x Lambda runtime. The AWS SDK is bundled too, so the deployed SDK version is the one
 * pinned in pnpm-lock.yaml rather than whatever the runtime happens to ship.
 *
 * The zip is reproducible (fixed mtimes, no extra attributes): unchanged code yields an unchanged
 * source_code_hash, so `terraform plan` shows no Lambda diff.
 */
import { execFileSync } from "node:child_process"
import { mkdirSync, rmSync, statSync, utimesSync } from "node:fs"
import { build } from "esbuild"

const outdir = "dist"
const files = ["index.mjs", "index.mjs.map"]

rmSync(outdir, { recursive: true, force: true })
mkdirSync(outdir)

await build({
  entryPoints: ["src/index.ts"],
  outfile: `${outdir}/index.mjs`,
  bundle: true,
  platform: "node",
  target: "node24",
  format: "esm",
  minify: true,
  sourcemap: true,
  legalComments: "none",
  // Some bundled CommonJS dependencies call require() for Node built-ins.
  banner: { js: "import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);" },
})

const epoch = new Date("2000-01-01T00:00:00Z")
for (const file of files) utimesSync(`${outdir}/${file}`, epoch, epoch)
execFileSync("zip", ["-q", "-X", "-D", "lambda.zip", ...files], { cwd: outdir })

const mib = (path) => (statSync(path).size / 1024 / 1024).toFixed(2)
console.log(`index.mjs=${mib(`${outdir}/index.mjs`)}MiB lambda.zip=${mib(`${outdir}/lambda.zip`)}MiB`)
