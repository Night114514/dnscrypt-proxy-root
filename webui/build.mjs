#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import {fileURLToPath} from 'node:url';

const webuiDir = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.dirname(webuiDir);
const outputDir = path.join(rootDir, 'webroot');
const checkOnly = process.argv.slice(2).includes('--check');
const unexpectedArgs = process.argv.slice(2).filter((arg) => arg !== '--check');

if (unexpectedArgs.length > 0) {
  throw new Error(`Unknown build argument: ${unexpectedArgs.join(' ')}`);
}

const files = new Map([
  ['index.html', 'src/index.html'],
  ['icon.svg', 'src/icon.svg'],
  ['assets/bridge.js', 'src/bridge.js'],
  ['assets/app.js', 'src/app.js'],
  ['assets/app.css', 'src/styles.css'],
]);

function sourceBytes(sourcePath) {
  return fs.readFileSync(path.join(webuiDir, sourcePath));
}

function outputFiles(directory, prefix = '') {
  if (!fs.existsSync(directory)) return [];
  return fs.readdirSync(directory, {withFileTypes: true})
    .flatMap((entry) => {
      const relativePath = path.posix.join(prefix, entry.name);
      const absolutePath = path.join(directory, entry.name);
      return entry.isDirectory() ? outputFiles(absolutePath, relativePath) : [relativePath];
    })
    .sort();
}

if (checkOnly) {
  const expectedPaths = [...files.keys()].sort();
  const actualPaths = outputFiles(outputDir);
  if (JSON.stringify(actualPaths) !== JSON.stringify(expectedPaths)) {
    throw new Error(`Generated WebUI file set differs. Expected ${expectedPaths.join(', ')}, got ${actualPaths.join(', ')}`);
  }
  for (const [outputPath, sourcePath] of files) {
    const expected = sourceBytes(sourcePath);
    const actual = fs.readFileSync(path.join(outputDir, ...outputPath.split('/')));
    if (!actual.equals(expected)) {
      throw new Error(`Generated WebUI file is stale: ${outputPath}`);
    }
  }
  console.log(`WebUI reproducibility check passed (${files.size} files, no external dependencies).`);
  process.exit(0);
}

fs.rmSync(outputDir, {recursive: true, force: true});
for (const [outputPath, sourcePath] of files) {
  const destination = path.join(outputDir, ...outputPath.split('/'));
  fs.mkdirSync(path.dirname(destination), {recursive: true});
  fs.writeFileSync(destination, sourceBytes(sourcePath));
}
console.log(`Built ${files.size} deterministic WebUI files from audited source.`);
