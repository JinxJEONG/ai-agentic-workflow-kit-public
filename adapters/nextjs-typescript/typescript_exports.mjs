#!/usr/bin/env node

import { createRequire } from "node:module";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const input = JSON.parse(readFileSync(0, "utf8"));
const root = resolve(input.root);

function candidates() {
  const values = [];
  try {
    const req = createRequire(join(root, "package.json"));
    values.push(req.resolve("typescript"));
  } catch {}

  const roots = [root];
  for (const parent of ["apps", "packages"]) {
    const directory = join(root, parent);
    if (!existsSync(directory)) continue;
    for (const child of readdirSync(directory)) roots.push(join(directory, child));
  }
  for (const base of roots) {
    values.push(join(base, "node_modules", "typescript", "lib", "typescript.js"));
    const pnpm = join(base, "node_modules", ".pnpm");
    if (!existsSync(pnpm)) continue;
    for (const entry of readdirSync(pnpm).filter((name) => name.startsWith("typescript@"))) {
      values.push(join(pnpm, entry, "node_modules", "typescript", "lib", "typescript.js"));
    }
  }
  return [...new Set(values)].filter(existsSync);
}

const modulePath = candidates()[0];
if (!modulePath) {
  process.stderr.write("TypeScript compiler API not found below the project root; refusing a lexical approximation\n");
  process.exit(30);
}

const imported = await import(pathToFileURL(modulePath));
const ts = imported.default ?? imported;
const exports = [];

for (const record of input.records) {
  const kind = record.path.endsWith("x") ? ts.ScriptKind.TSX : ts.ScriptKind.TS;
  const source = ts.createSourceFile(record.path, record.content, ts.ScriptTarget.Latest, true, kind);
  for (const diagnostic of source.parseDiagnostics ?? []) {
    process.stderr.write(`${record.path}: TypeScript parse error ${diagnostic.code}\n`);
    process.exit(30);
  }
  for (const statement of source.statements) {
    const modifiers = ts.canHaveModifiers(statement) ? ts.getModifiers(statement) ?? [] : [];
    const exported = modifiers.some((modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword);
    const isDefault = modifiers.some((modifier) => modifier.kind === ts.SyntaxKind.DefaultKeyword);
    if (ts.isExportDeclaration(statement)) {
      if (statement.exportClause && ts.isNamedExports(statement.exportClause)) {
        for (const element of statement.exportClause.elements) {
          exports.push({ path: record.path, name: element.name.text, kind: "re-export", default: false });
        }
      } else {
        exports.push({ path: record.path, name: "*", kind: "re-export", default: false });
      }
      continue;
    }
    if (ts.isExportAssignment(statement)) {
      exports.push({ path: record.path, name: "default", kind: "assignment", default: true });
      continue;
    }
    if (!exported) continue;
    if (statement.name?.text) {
      exports.push({ path: record.path, name: statement.name.text, kind: ts.SyntaxKind[statement.kind], default: isDefault });
    } else if (statement.declarationList) {
      for (const declaration of statement.declarationList.declarations) {
        if (ts.isIdentifier(declaration.name)) {
          exports.push({ path: record.path, name: declaration.name.text, kind: "variable", default: isDefault });
        }
      }
    } else if (isDefault) {
      exports.push({ path: record.path, name: "default", kind: ts.SyntaxKind[statement.kind], default: true });
    }
  }
}

exports.sort((left, right) =>
  left.path.localeCompare(right.path, "en") || left.name.localeCompare(right.name, "en")
);
process.stdout.write(JSON.stringify({ parser: `typescript-${ts.version}`, exports }));
