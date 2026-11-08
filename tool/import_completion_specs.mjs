#!/usr/bin/env node
// Static importer for withfig/autocomplete specs. Design, schema and limits: docs/COMPLETION_SPECS.md.
//
//   node tool/import_completion_specs.mjs --archive <fig.tar.gz> --typescript <typescript package dir>
//   node tool/import_completion_specs.mjs --source <extracted dir> --typescript <dir> --unpinned
//
// The downloaded sources are untrusted data. Nothing from them is imported, evaluated or executed: TypeScript is
// used for parsing only and the specs are interpreted from the syntax tree with a bounded evaluator.
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { gunzipSync } from 'node:zlib';

const MIB = 1024 * 1024;

export const PINNED = Object.freeze({
  packageName: '@withfig/autocomplete',
  repository: 'https://github.com/withfig/autocomplete',
  commit: 'aef52acff84c45edde61ae610cc2c964802b9a38',
  packageVersion: '2.692.3',
  archiveUrl: 'https://codeload.github.com/withfig/autocomplete/tar.gz/aef52acff84c45edde61ae610cc2c964802b9a38',
  typescriptVersion: '5.9.3',
  typescriptIntegrity:
    'sha512-jl1vZzPDinLr9eUt3J/t7V6FgNEw9QjvBPdysz9KfQDD41fQrC2Y4vKQdiaUpFT4bXlb1RHhLpp8wtm6M5TgSw==',
});

export const LIMITS = Object.freeze({
  maxArchiveBytes: 64 * MIB,
  maxUnpackedBytes: 384 * MIB,
  maxEntries: 20000,
  maxSourceFileBytes: 8 * MIB,
  maxSourceBytes: 256 * MIB,
  maxEvalStepsPerAsset: 5_000_000,
  maxEvalDepth: 256,
  maxCallDepth: 24,
  maxArrayLength: 20_000,
  maxImportDepth: 8,
  maxProjectDepth: 64,
  maxNodesPerAsset: 400_000,
  maxAssetBytes: 3 * MIB,
  maxTotalBytes: 56 * MIB,
  maxNestedChain: 16,
  moduleCacheBytes: 64 * MIB,
  descriptionChars: 160,
  maxSamplesPerAsset: 3,
});

const SCHEMA_VERSION = 1;
const ASSET_DIR = 'assets/completions';
const NAME_RE = /^[A-Za-z0-9._@+-]+$/;
const CONTROL_RE = /[\u0000-\u001f\u007f]/;
const RESERVED_WINDOWS_RE = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])$/i;

export class ImportError extends Error {}
export class BudgetError extends ImportError {}

const compare = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
const sha256 = (data) => createHash('sha256').update(data).digest('hex');
const increment = (map, key, by = 1) => map.set(key, (map.get(key) ?? 0) + by);
const sortedObject = (map) => Object.fromEntries([...map].sort(([a], [b]) => compare(a, b)));

// ---------------------------------------------------------------------------------------------------------------
// Source acquisition: only regular files are ever read, nothing is written to disk.

function isRelevantSource(rel) {
  return rel === 'LICENSE' || rel === 'package.json' || (/^src\/.+\.ts$/.test(rel) && !rel.endsWith('.d.ts'));
}

function checkSafeSegments(name) {
  if (name.includes('\0') || name.includes('\\') || name.startsWith('/') || /^[A-Za-z]:/.test(name)) {
    throw new ImportError(`unsafe path in source: ${JSON.stringify(name)}`);
  }
  const segments = name.split('/').filter((s) => s !== '');
  if (segments.some((s) => s === '..' || s === '.')) {
    throw new ImportError(`unsafe path in source: ${JSON.stringify(name)}`);
  }
  return segments;
}

class SourceCollector {
  constructor(limits) {
    this.limits = limits;
    this.files = new Map();
    this.bytes = 0;
    this.ignored = 0;
  }

  add(rel, data) {
    if (!isRelevantSource(rel)) {
      this.ignored++;
      return;
    }
    if (this.files.has(rel)) throw new ImportError(`duplicate source path: ${rel}`);
    if (data.length > this.limits.maxSourceFileBytes) throw new BudgetError(`source file too large: ${rel}`);
    this.bytes += data.length;
    if (this.bytes > this.limits.maxSourceBytes) throw new BudgetError('source files exceed the total size limit');
    this.files.set(rel, Buffer.from(data));
  }
}

function cString(buffer, start, length) {
  const slice = buffer.subarray(start, start + length);
  const end = slice.indexOf(0);
  return slice.subarray(0, end < 0 ? slice.length : end).toString('utf8');
}

function parseOctal(header, start, length) {
  if (header[start] & 0x80) throw new ImportError('base-256 tar sizes are not supported');
  const text = cString(header, start, length).trim();
  if (text === '') return 0;
  if (!/^[0-7]+$/.test(text)) throw new ImportError('corrupt tar header number');
  return Number.parseInt(text, 8);
}

function parsePax(data) {
  const records = {};
  let offset = 0;
  while (offset < data.length) {
    const space = data.indexOf(0x20, offset);
    if (space < 0) break;
    const length = Number.parseInt(data.subarray(offset, space).toString('ascii'), 10);
    if (!Number.isInteger(length) || length <= space - offset + 1 || offset + length > data.length) {
      throw new ImportError('corrupt tar pax record');
    }
    const record = data.subarray(space + 1, offset + length - 1).toString('utf8');
    const eq = record.indexOf('=');
    if (eq > 0) records[record.slice(0, eq)] = record.slice(eq + 1);
    offset += length;
  }
  return records;
}

/** Reads a tar.gz from memory; keeps only the whitelisted regular files. Links, devices and unsafe paths are refused. */
export function readTarGz(archive, { limits = LIMITS, expectedCommit = null } = {}) {
  if (archive.length > limits.maxArchiveBytes) throw new BudgetError('archive is too large');
  let tar;
  try {
    tar = gunzipSync(archive, { maxOutputLength: limits.maxUnpackedBytes });
  } catch (error) {
    throw new ImportError(`cannot decompress archive: ${error.message}`);
  }
  const collector = new SourceCollector(limits);
  let commit = null;
  let top = null;
  let pax = null;
  let longName = null;
  let entries = 0;
  let offset = 0;
  let ended = false;
  while (offset + 512 <= tar.length) {
    const header = tar.subarray(offset, offset + 512);
    if (header.every((b) => b === 0)) {
      ended = true;
      break;
    }
    let checksum = 0;
    for (let i = 0; i < 512; i++) checksum += i >= 148 && i < 156 ? 0x20 : header[i];
    if (checksum !== parseOctal(header, 148, 8)) throw new ImportError('tar header checksum mismatch');
    let name = cString(header, 0, 100);
    if (cString(header, 257, 5) === 'ustar') {
      const prefix = cString(header, 345, 155);
      if (prefix) name = `${prefix}/${name}`;
    }
    const type = header[156] === 0 ? '0' : String.fromCharCode(header[156]);
    let size = parseOctal(header, 124, 12);
    if (pax?.size !== undefined) size = Number.parseInt(pax.size, 10);
    offset += 512;
    if (!Number.isSafeInteger(size) || size < 0 || offset + size > tar.length) throw new ImportError('truncated tar');
    const data = tar.subarray(offset, offset + size);
    offset += Math.ceil(size / 512) * 512;

    if (type === 'g') {
      commit = parsePax(data).comment ?? commit;
      continue;
    }
    if (type === 'x') {
      pax = parsePax(data);
      continue;
    }
    if (type === 'L') {
      longName = cString(data, 0, data.length);
      continue;
    }
    if (type === 'K') continue;
    if (longName !== null) name = longName;
    if (pax?.path !== undefined) name = pax.path;
    longName = null;
    pax = null;

    if (++entries > limits.maxEntries) throw new BudgetError('archive has too many entries');
    const segments = checkSafeSegments(name);
    if (segments.length === 0) continue;
    if (top === null) top = segments[0];
    if (segments[0] !== top) throw new ImportError('archive has more than one top-level directory');
    const rel = segments.slice(1).join('/');
    if (type === '5') continue;
    if (type !== '0') {
      // Links and special files are never followed; they cannot influence what is read.
      collector.ignored++;
      continue;
    }
    if (rel !== '') collector.add(rel, data);
  }
  if (!ended) throw new ImportError('truncated tar: no end-of-archive marker');
  if (expectedCommit !== null && commit !== expectedCommit) {
    throw new ImportError(`archive commit ${commit} does not match ${expectedCommit}`);
  }
  return { files: collector.files, commit, ignored: collector.ignored };
}

/** Same whitelist as readTarGz for an already extracted directory; symbolic links are refused, not followed. */
export function readSourceDirectory(root, { limits = LIMITS } = {}) {
  const rootStat = lstatSync(root);
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) throw new ImportError('source must be a real directory');
  const collector = new SourceCollector(limits);
  const walk = (rel) => {
    const absolute = path.join(root, rel);
    for (const entry of readdirSync(absolute, { withFileTypes: true }).sort((a, b) => compare(a.name, b.name))) {
      const childRel = rel === '' ? entry.name : `${rel}/${entry.name}`;
      const stat = lstatSync(path.join(root, childRel));
      if (stat.isSymbolicLink()) throw new ImportError(`symbolic link in source: ${childRel}`);
      if (stat.isDirectory()) {
        if (rel === '' ? entry.name === 'src' : true) walk(childRel);
      } else if (stat.isFile()) {
        if (isRelevantSource(childRel)) collector.add(childRel, readFileSync(path.join(root, childRel)));
        else collector.ignored++;
      } else {
        throw new ImportError(`unsupported file type in source: ${childRel}`);
      }
    }
  };
  walk('');
  return { files: collector.files, commit: null, ignored: collector.ignored };
}

export function loadTypescript(dir, { pinned = true } = {}) {
  const root = existsSync(path.join(dir, 'package', 'package.json')) ? path.join(dir, 'package') : dir;
  const pkg = JSON.parse(readFileSync(path.join(root, 'package.json'), 'utf8'));
  if (pkg.name !== 'typescript') throw new ImportError('--typescript must point at the typescript package');
  if (pinned && pkg.version !== PINNED.typescriptVersion) {
    throw new ImportError(`typescript ${pkg.version} found, ${PINNED.typescriptVersion} required`);
  }
  const require = createRequire(pathToFileURL(path.join(root, 'package.json')));
  return { ts: require(path.join(root, 'lib', 'typescript.js')), version: pkg.version };
}

// ---------------------------------------------------------------------------------------------------------------
// Bounded evaluator over the TypeScript AST; nothing is ever executed. Values: string, number, boolean, null,
// undefined, Map (object), Array, FnValue, Unsupported. Calls are limited to pure helpers defined in the sources
// (expression or `const ...; return` bodies), a few Array methods and Object.keys/values/entries/Array.from.

class Unsupported {
  constructor(kind, detail = '') {
    this.kind = kind;
    this.detail = detail;
  }
}
/** A function value; `node` is null for placeholders (object methods) whose body is never evaluated. */
class FnValue {
  constructor(node = null, mod = null, frame = null) {
    this.node = node;
    this.mod = mod;
    this.frame = frame;
  }
}
const FUNCTION = new FnValue();
const isTruthy = (value) => !(value === undefined || value === null || value === false || value === 0 || value === '' || Number.isNaN(value));
class VersionedSpec {
  constructor(name, versions) {
    this.name = name;
    this.versions = versions;
  }
}

class Interpreter {
  constructor(ts, files, limits) {
    this.ts = ts;
    this.K = ts.SyntaxKind;
    this.files = files;
    this.limits = limits;
    this.modules = new Map();
    this.moduleBytes = 0;
    this.steps = 0;
    this.importDepth = 0;
    this.frame = null;
    this.callDepth = 0;
    this.syntaxErrors = new Map();
  }

  beginAsset() {
    this.steps = 0;
    this.frame = null;
    this.callDepth = 0;
    if (this.moduleBytes > this.limits.moduleCacheBytes) {
      this.modules.clear();
      this.moduleBytes = 0;
    }
  }

  module(file) {
    let mod = this.modules.get(file);
    if (mod) return mod;
    const buffer = this.files.get(file);
    const text = new TextDecoder('utf-8').decode(buffer);
    const sf = this.ts.createSourceFile(file, text, this.ts.ScriptTarget.Latest, false, this.ts.ScriptKind.TS);
    if (sf.parseDiagnostics?.length) this.syntaxErrors.set(file, sf.parseDiagnostics.length);
    mod = { path: file, sf, bindings: new Map(), exports: new Map(), stars: [] };
    this.collect(mod);
    this.modules.set(file, mod);
    this.moduleBytes += buffer.length;
    return mod;
  }

  hasModifier(node, kind) {
    return node.modifiers?.some((m) => m.kind === kind) ?? false;
  }

  collect(mod) {
    const { ts, K } = this;
    const exported = (node) => this.hasModifier(node, K.ExportKeyword);
    const isDefault = (node) => this.hasModifier(node, K.DefaultKeyword);
    for (const s of mod.sf.statements) {
      switch (s.kind) {
        case K.VariableStatement:
          for (const d of s.declarationList.declarations) {
            if (d.name.kind !== K.Identifier) {
              for (const element of d.name.elements ?? []) {
                if (element.name?.kind === K.Identifier) {
                  mod.bindings.set(element.name.text, { kind: 'unsupported', reason: 'destructuring' });
                }
              }
              continue;
            }
            const name = d.name.text;
            mod.bindings.set(name, d.initializer ? { kind: 'var', init: d.initializer, state: 0 } : { kind: 'unsupported', reason: 'uninitialized' });
            if (exported(s)) mod.exports.set(name, { kind: 'local', local: name });
          }
          break;
        case K.FunctionDeclaration: {
          const name = s.name?.text ?? '*default*';
          mod.bindings.set(name, { kind: 'fn', node: s });
          if (exported(s)) mod.exports.set(isDefault(s) ? 'default' : name, { kind: 'local', local: name });
          break;
        }
        case K.ClassDeclaration:
        case K.EnumDeclaration:
        case K.ModuleDeclaration: {
          const name = s.name?.text;
          if (name) mod.bindings.set(name, { kind: 'unsupported', reason: K[s.kind] });
          if (name && exported(s)) mod.exports.set(isDefault(s) ? 'default' : name, { kind: 'local', local: name });
          break;
        }
        case K.ImportDeclaration: {
          const clause = s.importClause;
          if (!clause || clause.isTypeOnly || s.moduleSpecifier.kind !== K.StringLiteral) break;
          const specifier = s.moduleSpecifier.text;
          if (clause.name) mod.bindings.set(clause.name.text, { kind: 'import', specifier, imported: 'default' });
          const named = clause.namedBindings;
          if (named?.kind === K.NamespaceImport) {
            mod.bindings.set(named.name.text, { kind: 'import', specifier, imported: '*' });
          } else if (named) {
            for (const element of named.elements) {
              if (element.isTypeOnly) continue;
              mod.bindings.set(element.name.text, {
                kind: 'import',
                specifier,
                imported: (element.propertyName ?? element.name).text,
              });
            }
          }
          break;
        }
        case K.ExportAssignment:
          if (!s.isExportEquals) mod.exports.set('default', { kind: 'expr', node: s.expression, state: 0 });
          break;
        case K.ExportDeclaration: {
          if (s.isTypeOnly) break;
          const specifier = s.moduleSpecifier?.kind === K.StringLiteral ? s.moduleSpecifier.text : null;
          const clause = s.exportClause;
          if (!clause) {
            if (specifier) mod.stars.push(specifier);
          } else if (clause.kind === K.NamedExports) {
            for (const element of clause.elements) {
              if (element.isTypeOnly) continue;
              const local = (element.propertyName ?? element.name).text;
              mod.exports.set(
                element.name.text,
                specifier ? { kind: 'reexport', specifier, imported: local } : { kind: 'local', local },
              );
            }
          }
          break;
        }
        default:
          break;
      }
    }
  }

  resolveModulePath(from, specifier) {
    if (!specifier.startsWith('./') && !specifier.startsWith('../')) return null;
    const base = path.posix.normalize(path.posix.join(path.posix.dirname(from), specifier.replace(/\.(js|ts)$/, '')));
    if (base.startsWith('..')) return null;
    for (const candidate of [`${base}.ts`, `${base}/index.ts`]) if (this.files.has(candidate)) return candidate;
    return null;
  }

  importedValue(mod, specifier, imported, depth) {
    if (!specifier.startsWith('./') && !specifier.startsWith('../')) return new Unsupported('external-import', specifier);
    const target = this.resolveModulePath(mod.path, specifier);
    if (!target) return new Unsupported('import-missing', specifier);
    if (this.importDepth >= this.limits.maxImportDepth) return new Unsupported('import-too-deep', specifier);
    this.importDepth++;
    try {
      const targetModule = this.module(target);
      if (imported !== '*') return this.exportValue(targetModule, imported, depth, new Set());
      const namespace = new Map();
      for (const name of targetModule.exports.keys()) namespace.set(name, this.exportValue(targetModule, name, depth, new Set()));
      return namespace;
    } finally {
      this.importDepth--;
    }
  }

  exportValue(mod, name, depth, seen) {
    if (seen.has(mod.path)) return new Unsupported('missing-export', name);
    seen.add(mod.path);
    const entry = mod.exports.get(name);
    if (entry) {
      if (entry.kind === 'local') return this.binding(mod, entry.local, depth);
      if (entry.kind === 'reexport') return this.importedValue(mod, entry.specifier, entry.imported, depth);
      if (entry.state === 2) return entry.value;
      if (entry.state === 1) return new Unsupported('cycle', name);
      entry.state = 1;
      entry.value = this.atModuleLevel(() => this.evaluate(entry.node, mod, depth + 1));
      entry.state = 2;
      return entry.value;
    }
    if (name !== 'default') {
      for (const specifier of mod.stars) {
        const target = this.resolveModulePath(mod.path, specifier);
        if (!target) continue;
        const value = this.exportValue(this.module(target), name, depth, seen);
        if (!(value instanceof Unsupported && value.kind === 'missing-export')) return value;
      }
    }
    return new Unsupported('missing-export', name);
  }

  binding(mod, name, depth) {
    const b = mod.bindings.get(name);
    if (!b) return name === 'undefined' ? undefined : new Unsupported('free-identifier', name);
    switch (b.kind) {
      case 'fn':
        return new FnValue(b.node, mod, null);
      case 'unsupported':
        return new Unsupported(b.reason, name);
      case 'import':
        return this.importedValue(mod, b.specifier, b.imported, depth);
      default:
        if (b.state === 2) return b.value;
        if (b.state === 1) return new Unsupported('cycle', name);
        b.state = 1;
        b.value = this.atModuleLevel(() => this.evaluate(b.init, mod, depth + 1));
        b.state = 2;
        return b.value;
    }
  }

  /** Module-level initializers never see the locals of whichever function call happens to trigger them. */
  atModuleLevel(run) {
    const saved = this.frame;
    this.frame = null;
    try {
      return run();
    } finally {
      this.frame = saved;
    }
  }

  identifier(mod, name, depth) {
    for (let frame = this.frame; frame !== null; frame = frame.parent) {
      if (frame.vars.has(name)) return frame.vars.get(name);
    }
    return this.binding(mod, name, depth);
  }

  isFree(mod, name) {
    for (let frame = this.frame; frame !== null; frame = frame.parent) if (frame.vars.has(name)) return false;
    return !mod.bindings.has(name);
  }

  defaultExport(file) {
    return this.exportValue(this.module(file), 'default', 0, new Set());
  }

  calleeText(node, mod) {
    return node.expression.getText(mod.sf).replace(/\s+/g, ' ').slice(0, 60);
  }

  evaluate(node, mod, depth = 0) {
    if (++this.steps > this.limits.maxEvalStepsPerAsset) throw new BudgetError(`evaluation step budget exceeded in ${mod.path}`);
    if (depth > this.limits.maxEvalDepth) return new Unsupported('too-deep');
    const { K } = this;
    switch (node.kind) {
      case K.StringLiteral:
      case K.NoSubstitutionTemplateLiteral:
        return node.text;
      case K.NumericLiteral:
        return Number(node.text);
      case K.TrueKeyword:
        return true;
      case K.FalseKeyword:
        return false;
      case K.NullKeyword:
        return null;
      case K.ParenthesizedExpression:
      case K.AsExpression:
      case K.SatisfiesExpression:
      case K.TypeAssertionExpression:
      case K.NonNullExpression:
        return this.evaluate(node.expression, mod, depth + 1);
      case K.Identifier:
        return this.identifier(mod, node.text, depth);
      case K.ArrowFunction:
      case K.FunctionExpression:
        return new FnValue(node, mod, this.frame);
      case K.TypeOfExpression: {
        const value = this.evaluate(node.expression, mod, depth + 1);
        if (value instanceof Unsupported) return value;
        return value instanceof FnValue ? 'function' : value === null ? 'object' : typeof value;
      }
      case K.PrefixUnaryExpression: {
        const value = this.evaluate(node.operand, mod, depth + 1);
        if (value instanceof Unsupported) return value;
        const { ts } = this;
        if (node.operator === ts.SyntaxKind.MinusToken && typeof value === 'number') return -value;
        if (node.operator === ts.SyntaxKind.PlusToken && typeof value === 'number') return value;
        if (node.operator === ts.SyntaxKind.ExclamationToken) return !isTruthy(value);
        return new Unsupported('unary');
      }
      case K.TemplateExpression: {
        let text = node.head.text;
        for (const span of node.templateSpans) {
          const value = this.evaluate(span.expression, mod, depth + 1);
          if (typeof value !== 'string' && typeof value !== 'number') return new Unsupported('template', 'non-static substitution');
          text += String(value) + span.literal.text;
        }
        return text;
      }
      case K.ObjectLiteralExpression:
        return this.object(node, mod, depth);
      case K.ArrayLiteralExpression:
        return this.array(node, mod, depth);
      case K.PropertyAccessExpression:
      case K.ElementAccessExpression: {
        const target = this.evaluate(node.expression, mod, depth + 1);
        if (target instanceof Unsupported) return target;
        const key = node.kind === K.PropertyAccessExpression ? node.name.text : this.evaluate(node.argumentExpression, mod, depth + 1);
        if (typeof key !== 'string' && typeof key !== 'number') return new Unsupported('member-access', 'dynamic key');
        if (target instanceof Map) return target.has(String(key)) ? target.get(String(key)) : undefined;
        if (Array.isArray(target)) return key === 'length' ? target.length : target[key];
        return new Unsupported('member-access', String(key));
      }
      case K.BinaryExpression:
        return this.binary(node, mod, depth);
      case K.ConditionalExpression: {
        const condition = this.evaluate(node.condition, mod, depth + 1);
        if (condition instanceof Unsupported) return condition;
        return this.evaluate(isTruthy(condition) ? node.whenTrue : node.whenFalse, mod, depth + 1);
      }
      case K.CallExpression:
        return this.call(node, mod, depth);
      default:
        return new Unsupported(K[node.kind] ?? 'unknown');
    }
  }

  call(node, mod, depth) {
    const { K } = this;
    if (node.expression.kind === K.Identifier && node.expression.text === 'createVersionedSpec') {
      const b = mod.bindings.get('createVersionedSpec');
      if (b?.kind === 'import' && b.specifier === '@fig/autocomplete-helpers' && node.arguments.length >= 2) {
        const name = this.evaluate(node.arguments[0], mod, depth + 1);
        const versions = this.evaluate(node.arguments[1], mod, depth + 1);
        if (typeof name === 'string' && Array.isArray(versions) && versions.every((v) => typeof v === 'string')) {
          return new VersionedSpec(name, versions);
        }
        return new Unsupported('versioned-spec', 'non-literal arguments');
      }
    }
    const unsupported = () => new Unsupported('call', this.calleeText(node, mod));
    const callee = node.expression;
    if (callee.kind === K.PropertyAccessExpression) {
      const owner = callee.expression;
      const method = callee.name.text;
      if (owner.kind === K.Identifier && (owner.text === 'Object' || owner.text === 'Array') && this.isFree(mod, owner.text)) {
        const args = this.callArguments(node, mod, depth);
        return args === null ? unsupported() : this.builtin(`${owner.text}.${method}`, args, depth) ?? unsupported();
      }
      const receiver = this.evaluate(owner, mod, depth + 1);
      if (Array.isArray(receiver)) {
        const args = this.callArguments(node, mod, depth);
        return args === null ? unsupported() : this.arrayMethod(receiver, method, args, depth) ?? unsupported();
      }
      if (receiver instanceof Map) {
        const member = receiver.get(method);
        if (member instanceof FnValue && member.node !== null) {
          const args = this.callArguments(node, mod, depth);
          return args === null ? unsupported() : this.invoke(member, args, depth + 1);
        }
      }
      return unsupported();
    }
    const fn = this.evaluate(callee, mod, depth + 1);
    if (fn instanceof FnValue && fn.node !== null) {
      const args = this.callArguments(node, mod, depth);
      return args === null ? unsupported() : this.invoke(fn, args, depth + 1);
    }
    return unsupported();
  }

  /** Argument values for a call; null when a spread argument is not a static array. */
  callArguments(node, mod, depth) {
    const { K } = this;
    const args = [];
    for (const argument of node.arguments) {
      if (argument.kind === K.SpreadElement) {
        const value = this.evaluate(argument.expression, mod, depth + 1);
        if (!Array.isArray(value)) return null;
        args.push(...value);
      } else {
        args.push(this.evaluate(argument, mod, depth + 1));
      }
    }
    return args;
  }

  /** Runs a helper defined in the sources: parameters, `const` locals and one `return` are supported, nothing else. */
  invoke(fn, args, depth) {
    const { K } = this;
    const node = fn.node;
    if (this.callDepth >= this.limits.maxCallDepth) return new Unsupported('call-depth');
    if (node.body === undefined) return new Unsupported('call', 'no body');
    const vars = new Map();
    const saved = this.frame;
    this.frame = { vars, parent: fn.frame };
    this.callDepth++;
    try {
      for (const [index, parameter] of node.parameters.entries()) {
        if (parameter.name.kind !== K.Identifier || parameter.dotDotDotToken) return new Unsupported('call', 'parameter pattern');
        let value = args[index];
        if (value === undefined && parameter.initializer) value = this.evaluate(parameter.initializer, fn.mod, depth + 1);
        vars.set(parameter.name.text, value);
      }
      if (node.body.kind !== K.Block) return this.evaluate(node.body, fn.mod, depth + 1);
      for (const statement of node.body.statements) {
        switch (statement.kind) {
          case K.VariableStatement:
            for (const declaration of statement.declarationList.declarations) {
              if (declaration.name.kind !== K.Identifier || !declaration.initializer) return new Unsupported('call', 'local declaration');
              vars.set(declaration.name.text, this.evaluate(declaration.initializer, fn.mod, depth + 1));
            }
            break;
          case K.FunctionDeclaration:
            if (statement.name) vars.set(statement.name.text, new FnValue(statement, fn.mod, this.frame));
            break;
          case K.ReturnStatement:
            return statement.expression ? this.evaluate(statement.expression, fn.mod, depth + 1) : undefined;
          case K.InterfaceDeclaration:
          case K.TypeAliasDeclaration:
            break;
          default:
            return new Unsupported('call', `statement ${K[statement.kind]}`);
        }
      }
      return undefined;
    } finally {
      this.callDepth--;
      this.frame = saved;
    }
  }

  /** Object.keys/values/entries and Array.from; undefined when not supported. */
  builtin(name, args, depth) {
    const [subject, mapper] = args;
    switch (name) {
      case 'Object.keys':
      case 'Object.values':
      case 'Object.entries': {
        if (!(subject instanceof Map) || subject.taint) return undefined;
        if (name === 'Object.keys') return [...subject.keys()];
        if (name === 'Object.values') return [...subject.values()];
        return [...subject].map(([key, value]) => [key, value]);
      }
      case 'Array.from': {
        let items;
        if (Array.isArray(subject)) items = [...subject];
        else if (subject instanceof Map && typeof subject.get('length') === 'number' && !subject.taint) {
          const length = subject.get('length');
          if (!Number.isInteger(length) || length < 0 || length > this.limits.maxArrayLength) return undefined;
          items = new Array(length).fill(undefined);
        } else return undefined;
        if (mapper === undefined) return items;
        if (!(mapper instanceof FnValue) || mapper.node === null) return undefined;
        return items.map((item, index) => this.invoke(mapper, [item, index], depth + 1));
      }
      default:
        return undefined;
    }
  }

  arrayMethod(receiver, method, args, depth) {
    const [first] = args;
    switch (method) {
      case 'concat': {
        const result = [...receiver];
        for (const value of args) {
          if (Array.isArray(value)) result.push(...value);
          else result.push(value);
        }
        return result;
      }
      case 'map':
        if (!(first instanceof FnValue) || first.node === null) return undefined;
        return receiver.map((item, index) => this.invoke(first, [item, index, receiver], depth + 1));
      case 'filter': {
        if (!(first instanceof FnValue) || first.node === null) return undefined;
        const result = [];
        for (const [index, item] of receiver.entries()) {
          const keep = this.invoke(first, [item, index, receiver], depth + 1);
          if (keep instanceof Unsupported) return keep;
          if (isTruthy(keep)) result.push(item);
        }
        return result;
      }
      case 'join': {
        const separator = first === undefined ? ',' : first;
        if (typeof separator !== 'string') return undefined;
        const parts = receiver.map((item) => (typeof item === 'string' || typeof item === 'number' ? String(item) : null));
        return parts.includes(null) ? undefined : parts.join(separator);
      }
      case 'includes':
        if (first !== null && typeof first === 'object') return undefined;
        if (receiver.some((item) => item !== null && typeof item === 'object')) return undefined;
        return receiver.includes(first);
      default:
        return undefined;
    }
  }

  binary(node, mod, depth) {
    const { K } = this;
    const op = node.operatorToken.kind;
    const left = this.evaluate(node.left, mod, depth + 1);
    if (op === K.QuestionQuestionToken) {
      if (left instanceof Unsupported) return left;
      return left === null || left === undefined ? this.evaluate(node.right, mod, depth + 1) : left;
    }
    if (op === K.BarBarToken || op === K.AmpersandAmpersandToken) {
      if (left instanceof Unsupported) return left;
      const takeRight = op === K.BarBarToken ? !isTruthy(left) : isTruthy(left);
      return takeRight ? this.evaluate(node.right, mod, depth + 1) : left;
    }
    const right = this.evaluate(node.right, mod, depth + 1);
    if (left instanceof Unsupported) return left;
    if (right instanceof Unsupported) return right;
    if (op === K.PlusToken) {
      if (typeof left === 'string' && ['string', 'number'].includes(typeof right)) return left + right;
      if (typeof left === 'number' && typeof right === 'string') return left + right;
      if (typeof left === 'number' && typeof right === 'number') return left + right;
    }
    if (op === K.EqualsEqualsEqualsToken && typeof left === typeof right && typeof left !== 'object') return left === right;
    if (op === K.ExclamationEqualsEqualsToken && typeof left === typeof right && typeof left !== 'object') return left !== right;
    return new Unsupported('binary', this.ts.tokenToString(op) ?? K[op]);
  }

  propertyKey(name, mod, depth) {
    const { K } = this;
    switch (name.kind) {
      case K.Identifier:
      case K.StringLiteral:
      case K.NoSubstitutionTemplateLiteral:
      case K.NumericLiteral:
        return name.text;
      case K.ComputedPropertyName: {
        const value = this.evaluate(name.expression, mod, depth + 1);
        return typeof value === 'string' || typeof value === 'number' ? String(value) : null;
      }
      default:
        return null;
    }
  }

  object(node, mod, depth) {
    const { K } = this;
    const result = new Map();
    const taint = [];
    for (const p of node.properties) {
      switch (p.kind) {
        case K.PropertyAssignment: {
          const key = this.propertyKey(p.name, mod, depth);
          if (key === null) taint.push('computed-key');
          else result.set(key, this.evaluate(p.initializer, mod, depth + 1));
          break;
        }
        case K.ShorthandPropertyAssignment:
          result.set(p.name.text, this.identifier(mod, p.name.text, depth));
          break;
        case K.SpreadAssignment: {
          const value = this.evaluate(p.expression, mod, depth + 1);
          if (value instanceof Map) {
            for (const [k, v] of value) result.set(k, v);
            if (value.taint) taint.push(...value.taint);
          } else if (value instanceof Unsupported) taint.push(`spread:${value.kind}`);
          else if (value !== null && value !== undefined) taint.push('spread:non-object');
          break;
        }
        case K.MethodDeclaration: {
          const key = this.propertyKey(p.name, mod, depth);
          if (key === null) taint.push('computed-key');
          else result.set(key, FUNCTION);
          break;
        }
        default:
          taint.push(K[p.kind] ?? 'unknown-property');
      }
    }
    if (taint.length > 0) result.taint = taint;
    return result;
  }

  array(node, mod, depth) {
    const { K } = this;
    const result = [];
    for (const element of node.elements) {
      if (element.kind === K.SpreadElement) {
        const value = this.evaluate(element.expression, mod, depth + 1);
        if (Array.isArray(value)) result.push(...value);
        else result.push(value instanceof Unsupported ? value : new Unsupported('spread', 'non-array'));
      } else if (element.kind === K.OmittedExpression) {
        result.push(undefined);
      } else {
        result.push(this.evaluate(element, mod, depth + 1));
      }
    }
    return result;
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Projection of evaluated values to the output schema.

const FIELD_ORDER = {
  subcommand: [
    'name', 'displayName', 'description', 'insertValue', 'priority', 'hidden', 'deprecated', 'isDangerous',
    'requiresSubcommand', 'parserDirectives', 'loadSpec', 'subcommands', 'options', 'args', 'additionalSuggestions',
  ],
  option: [
    'name', 'displayName', 'description', 'insertValue', 'priority', 'hidden', 'deprecated', 'isDangerous',
    'isPersistent', 'isRequired', 'requiresEquals', 'isRepeatable', 'requiresSeparator', 'exclusiveOn', 'dependsOn',
    'args',
  ],
  arg: [
    'name', 'description', 'isDangerous', 'isOptional', 'isVariadic', 'isCommand', 'isScript', 'isModule',
    'optionsCanBreakVariadicArg', 'suggestCurrentToken', 'default', 'template', 'loadSpec', 'suggestions',
  ],
  suggestion: [
    'name', 'displayName', 'description', 'insertValue', 'priority', 'hidden', 'deprecated', 'isDangerous',
  ],
};
const FIELD_KIND = {
  name: 'name', displayName: 'str', description: 'desc', insertValue: 'insert', priority: 'priority',
  hidden: 'flag', deprecated: 'deprecated', isDangerous: 'flag', requiresSubcommand: 'flag',
  parserDirectives: 'parser', isPersistent: 'flag', isRequired: 'flag', requiresEquals: 'flag',
  isRepeatable: 'repeat', requiresSeparator: 'separator', exclusiveOn: 'strings', dependsOn: 'strings',
  isOptional: 'flag', isVariadic: 'flag', isCommand: 'flag', isScript: 'flag', isModule: 'module',
  optionsCanBreakVariadicArg: 'flag', suggestCurrentToken: 'flag', default: 'default', template: 'template',
};
const STRUCTURAL = new Set(['loadSpec', 'subcommands', 'options', 'args', 'additionalSuggestions', 'suggestions']);
const ALLOWED = Object.fromEntries(Object.entries(FIELD_ORDER).map(([type, keys]) => [type, new Set(keys)]));
const PARSER_FLAGS = new Set(['flagsArePosixNoncompliant', 'optionsMustPrecedeArguments']);

class Collector {
  constructor(key, source, limits) {
    this.key = key;
    this.source = source;
    this.limits = limits;
    this.nodes = 0;
    this.unsupported = new Map();
    this.omitted = new Map();
    this.dropped = new Map();
    this.truncated = 0;
    this.samples = [];
    this.path = [key];
    this.loadSpecs = { linked: 0, inline: 0, unresolved: 0, dynamic: 0 };
  }

  unsupportedValue(value, field) {
    increment(this.unsupported, value.kind);
    if (this.samples.length < this.limits.maxSamplesPerAsset) {
      this.samples.push({ path: this.path.join(' ').slice(0, 160), field, kind: value.kind, detail: value.detail });
    }
  }
  omit(field) {
    increment(this.omitted, field);
  }
  drop(reason) {
    increment(this.dropped, reason);
  }
}

function cleanDescription(text, max) {
  const flat = text.replace(/\s+/g, ' ').trim();
  if (flat === '') return { value: undefined, truncated: false };
  if (flat.length <= max) return { value: flat, truncated: false };
  let cut = max - 1;
  const code = flat.charCodeAt(cut - 1);
  if (code >= 0xd800 && code <= 0xdbff) cut--;
  let slice = flat.slice(0, cut);
  const space = slice.lastIndexOf(' ');
  if (space >= (cut * 2) / 3) slice = slice.slice(0, space);
  return { value: `${slice.replace(/[\s,;:.\-]+$/, '')}…`, truncated: true };
}

class Projector {
  constructor(limits, resolveLoadSpec) {
    this.limits = limits;
    this.resolveLoadSpec = resolveLoadSpec;
  }

  nameOf(raw, st) {
    const clean = (value) => (typeof value === 'string' && value !== '' && !CONTROL_RE.test(value) ? value : null);
    if (Array.isArray(raw)) {
      const names = [];
      for (const item of raw) {
        const name = clean(item);
        if (name !== null) names.push(name);
        else if (item instanceof Unsupported) st.unsupportedValue(item, 'name');
        else st.drop('name:invalid');
      }
      return names.length === 0 ? undefined : names.length === 1 ? names[0] : names;
    }
    if (raw instanceof Unsupported) {
      st.unsupportedValue(raw, 'name');
      return undefined;
    }
    return clean(raw) ?? undefined;
  }

  scalar(kind, raw, st, key) {
    if (raw === undefined) return undefined;
    if (raw instanceof Unsupported) {
      st.unsupportedValue(raw, key);
      return undefined;
    }
    if (raw instanceof FnValue) {
      st.omit(`${key}:function`);
      return undefined;
    }
    const mismatch = () => {
      st.drop(`${key}:type`);
      return undefined;
    };
    switch (kind) {
      case 'str':
        return typeof raw === 'string' && raw !== '' && !CONTROL_RE.test(raw) ? raw : mismatch();
      case 'desc': {
        if (typeof raw !== 'string') return mismatch();
        const { value, truncated } = cleanDescription(raw, this.limits.descriptionChars);
        if (truncated) st.truncated++;
        return value !== undefined && !CONTROL_RE.test(value) ? value : undefined;
      }
      case 'insert':
        if (typeof raw !== 'string' || raw === '') return mismatch();
        if (CONTROL_RE.test(raw)) {
          st.drop('insertValue:control-chars');
          return undefined;
        }
        return raw;
      case 'priority':
        return typeof raw === 'number' && Number.isFinite(raw) && raw >= 0 && raw <= 100 ? raw : mismatch();
      case 'flag':
        return raw === true ? true : raw === false || raw === null ? undefined : mismatch();
      case 'deprecated':
        return raw === true || raw instanceof Map ? true : raw === false || raw === null ? undefined : mismatch();
      case 'repeat':
        if (raw === true) return true;
        if (raw === false || raw === null) return undefined;
        return Number.isInteger(raw) && raw >= 2 ? raw : raw === 1 || raw === 0 ? undefined : mismatch();
      case 'separator':
        if (raw === true) return true;
        if (raw === false || raw === null) return undefined;
        return typeof raw === 'string' && raw !== '' && !CONTROL_RE.test(raw) ? raw : mismatch();
      case 'module':
        if (raw === true) return true;
        if (raw === false || raw === null) return undefined;
        return typeof raw === 'string' && raw !== '' && !CONTROL_RE.test(raw) ? raw : mismatch();
      case 'default':
        if (typeof raw === 'number' && Number.isFinite(raw)) return String(raw);
        return typeof raw === 'string' && raw !== '' && !CONTROL_RE.test(raw) ? raw : mismatch();
      case 'strings':
        return this.stringList(raw, st, key, false);
      case 'template': {
        if (typeof raw === 'string') return raw !== '' && !CONTROL_RE.test(raw) ? raw : mismatch();
        return this.stringList(raw, st, key, true);
      }
      case 'parser':
        return this.parserDirectives(raw, st);
      case 'name':
        return this.nameOf(raw, st);
      default:
        throw new Error(`unknown field kind ${kind}`);
    }
  }

  stringList(raw, st, key, collapseSingle) {
    if (!Array.isArray(raw)) {
      st.drop(`${key}:type`);
      return undefined;
    }
    const items = [];
    for (const item of raw) {
      if (typeof item === 'string' && item !== '' && !CONTROL_RE.test(item)) items.push(item);
      else if (item instanceof Unsupported) st.unsupportedValue(item, key);
      else if (item instanceof FnValue) st.omit(`${key}:function`);
      else st.drop(`${key}:item`);
    }
    if (items.length === 0) return undefined;
    return collapseSingle && items.length === 1 ? items[0] : items;
  }

  parserDirectives(raw, st) {
    if (!(raw instanceof Map)) {
      st.drop('parserDirectives:type');
      return undefined;
    }
    const out = {};
    for (const [key, value] of raw) {
      if (PARSER_FLAGS.has(key)) {
        if (value === true) out[key] = true;
        else if (value instanceof Unsupported) st.unsupportedValue(value, `parserDirectives.${key}`);
      } else if (key === 'optionArgSeparators') {
        const separators = typeof value === 'string' ? [value] : Array.isArray(value) ? value : null;
        const clean = separators?.filter((s) => typeof s === 'string' && s !== '' && !CONTROL_RE.test(s));
        if (clean?.length) out[key] = clean.length === 1 ? clean[0] : clean;
        else if (value instanceof Unsupported) st.unsupportedValue(value, `parserDirectives.${key}`);
      } else {
        st.omit(`parserDirectives.${key}`);
      }
    }
    return Object.keys(out).length === 0 ? undefined : out;
  }

  // Returns the output node, or null when the value cannot form a node of this type.
  node(type, value, st, field, projectDepth, nestedChain) {
    if (value instanceof Unsupported) {
      st.unsupportedValue(value, field);
      return null;
    }
    if (value instanceof FnValue) {
      st.omit(`${field}:function`);
      return null;
    }
    if (!(value instanceof Map)) {
      st.drop(`${field}:not-object`);
      return null;
    }
    if (projectDepth > this.limits.maxProjectDepth) {
      st.drop('too-deep');
      return null;
    }
    if (++st.nodes > this.limits.maxNodesPerAsset) throw new BudgetError(`node budget exceeded in ${st.source}`);
    const out = {};
    const name = this.scalar('name', value.get('name'), st, 'name');
    if (name === undefined && type !== 'arg') {
      st.drop(`${type}:no-name`);
      return null;
    }
    const label = Array.isArray(name) ? name[0] : (name ?? `arg${st.nodes}`);
    if (projectDepth > 0) st.path.push(label); // the asset key already names the root
    for (const key of value.keys()) if (!ALLOWED[type].has(key)) st.omit(key);
    for (const kind of value.taint ?? []) st.unsupportedValue(new Unsupported(kind, 'object'), 'object');
    for (const key of FIELD_ORDER[type]) {
      if (!value.has(key)) continue;
      const raw = value.get(key);
      if (key === 'name') {
        if (name !== undefined) out.name = name;
      } else if (!STRUCTURAL.has(key)) {
        const converted = this.scalar(FIELD_KIND[key], raw, st, key);
        if (converted !== undefined) out[key] = converted;
      } else {
        this.structural(type, key, raw, out, st, projectDepth, nestedChain);
      }
    }
    if (projectDepth > 0) st.path.pop();
    if (type === 'suggestion') {
      const keys = Object.keys(out);
      if (keys.length === 1 && typeof out.name === 'string') return out.name;
    }
    return out;
  }

  list(type, raw, st, key, projectDepth, nestedChain) {
    if (raw === undefined) return undefined;
    if (!Array.isArray(raw)) {
      if (raw instanceof Unsupported) st.unsupportedValue(raw, key);
      else if (raw instanceof FnValue) st.omit(`${key}:function`);
      else st.drop(`${key}:type`);
      return undefined;
    }
    const items = [];
    for (const item of raw) {
      if (type === 'suggestion' && typeof item === 'string') {
        if (item !== '' && !CONTROL_RE.test(item)) {
          st.nodes++;
          items.push(item);
        } else st.drop('suggestion:invalid-string');
        continue;
      }
      const projected = this.node(type, item, st, key, projectDepth + 1, nestedChain);
      if (projected !== null) items.push(projected);
    }
    return items.length === 0 ? undefined : items;
  }

  structural(type, key, raw, out, st, projectDepth, nestedChain) {
    if (key === 'subcommands') {
      const items = this.list('subcommand', raw, st, key, projectDepth, nestedChain);
      if (items) out.subcommands = items;
    } else if (key === 'options') {
      const items = this.list('option', raw, st, key, projectDepth, nestedChain);
      if (items) out.options = items;
    } else if (key === 'suggestions' || key === 'additionalSuggestions') {
      const items = this.list('suggestion', raw, st, key, projectDepth, nestedChain);
      if (items) out[key] = items;
    } else if (key === 'args') {
      if (Array.isArray(raw)) {
        const items = this.list('arg', raw, st, key, projectDepth, nestedChain);
        if (items) out.args = items;
      } else if (raw !== undefined) {
        const arg = this.node('arg', raw, st, key, projectDepth + 1, nestedChain);
        if (arg !== null) out.args = arg;
      }
    } else if (key === 'loadSpec') {
      this.loadSpec(raw, out, st, projectDepth, nestedChain);
    }
  }

  loadSpec(raw, out, st, projectDepth, nestedChain) {
    if (raw === undefined) return;
    if (typeof raw === 'string') {
      if (this.resolveLoadSpec(raw, st, nestedChain)) {
        out.loadSpec = raw;
        st.loadSpecs.linked++;
      }
    } else if (raw instanceof FnValue) {
      st.omit('loadSpec:function');
      st.loadSpecs.dynamic++;
    } else if (raw instanceof Unsupported) {
      st.unsupportedValue(raw, 'loadSpec');
      st.loadSpecs.dynamic++;
    } else if (raw instanceof Map) {
      const inline = this.node('subcommand', raw, st, 'loadSpec', projectDepth + 1, nestedChain);
      if (inline !== null) {
        out.loadSpec = inline;
        st.loadSpecs.inline++;
      }
    } else {
      st.drop('loadSpec:type');
    }
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Orchestration.

function compareVersions(a, b) {
  const split = (v) => v.split(/[.-]/).map((p) => (/^\d+$/.test(p) ? Number(p) : p));
  const left = split(a);
  const right = split(b);
  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    const x = left[i] ?? 0;
    const y = right[i] ?? 0;
    if (x === y) continue;
    if (typeof x === 'number' && typeof y === 'number') return x - y;
    return compare(String(x), String(y));
  }
  return 0;
}

export function assetFileName(key) {
  let name = key.replaceAll('/', '__').replace(/[^A-Za-z0-9._@+-]/g, (c) => {
    return [...Buffer.from(c, 'utf8')].map((b) => `_x${b.toString(16).padStart(2, '0')}_`).join('');
  });
  if (RESERVED_WINDOWS_RE.test(name.split('.')[0])) name = `_r_${name}`;
  return `${name}.json`;
}

function discoverRoots(files) {
  const roots = new Map();
  const conflicts = [];
  const nonRoot = [];
  for (const file of [...files.keys()].sort(compare)) {
    if (!file.startsWith('src/')) continue;
    const parts = file.slice(4).split('/');
    let key = null;
    if (parts.length === 1) key = parts[0].replace(/\.ts$/, '');
    else if (parts.length === 2 && parts[0].startsWith('@') && parts[1] !== 'index.ts') key = `${parts[0]}/${parts[1].replace(/\.ts$/, '')}`;
    else if (parts.at(-1) === 'index.ts' && parts.length === 2 && !parts[0].startsWith('@')) key = parts[0];
    else if (parts.at(-1) === 'index.ts' && parts.length === 3 && parts[0].startsWith('@')) key = `${parts[0]}/${parts[1]}`;
    if (key === null || key === '') {
      nonRoot.push(file);
      continue;
    }
    if (roots.has(key)) conflicts.push({ key, kept: roots.get(key), ignored: file });
    else roots.set(key, file);
  }
  return { roots, conflicts, nonRoot };
}

function safeTarget(target) {
  if (typeof target !== 'string' || target === '' || target.length > 200) return null;
  if (target.includes('\\') || target.includes('\0') || target.startsWith('/') || /^[A-Za-z]:/.test(target)) return null;
  const normalized = path.posix.normalize(target);
  if (normalized !== target || normalized.startsWith('..') || normalized.endsWith('/')) return null;
  return target;
}

export function importSpecs({ sources, ts, limits = LIMITS, pinned = null, archive = null, parser = null, exclude = [] }) {
  const excludeList = [...exclude].sort(compare);
  const isExcluded = (key) => excludeList.some((e) => key === e || key.startsWith(`${e}/`));
  const { files } = sources;
  const interpreter = new Interpreter(ts, files, limits);
  const packageJson = files.has('package.json') ? JSON.parse(files.get('package.json').toString('utf8')) : {};
  const license = files.get('LICENSE');
  if (!license) throw new ImportError('LICENSE is missing from the source');
  if (pinned) {
    if (sources.commit !== null && sources.commit !== pinned.commit) throw new ImportError('commit mismatch');
    if (packageJson.version !== pinned.packageVersion) {
      throw new ImportError(`package version ${packageJson.version} does not match ${pinned.packageVersion}`);
    }
  }

  const { roots, conflicts: rootConflicts, nonRoot } = discoverRoots(files);
  const excludedRoots = [];
  for (const key of [...roots.keys()]) {
    if (isExcluded(key)) {
      excludedRoots.push(key);
      roots.delete(key);
    }
  }
  const assets = new Map(); // asset key -> {key, source, file, json, audit}
  const bySource = new Map();
  const failedRoots = [];
  const failedNested = [];
  const versioned = [];
  const nested = new Map(); // loadSpec string -> asset key
  const rootSources = new Map(); // final source -> root key (first by sorted order)
  const rootFinal = new Map(); // root key -> final source
  let totalBytes = 0;
  let maxChain = 0;

  // Resolves index.ts roots to the highest version file; everything else is its own source.
  const finalSource = (file, label) => {
    if (!file.endsWith('/index.ts')) return { source: file };
    interpreter.beginAsset();
    const value = interpreter.defaultExport(file);
    if (value instanceof VersionedSpec) {
      const candidates = [...value.versions].sort(compareVersions);
      const chosen = candidates.at(-1);
      const source = chosen === undefined ? null : `src/${value.name}/${chosen}.ts`;
      if (source === null || !files.has(source)) return { failure: `versioned spec ${label} has no usable version file` };
      versioned.push({ key: label, name: value.name, versions: candidates, chosen, source });
      return { source };
    }
    return { source: file };
  };

  for (const [key, file] of roots) {
    const resolved = finalSource(file, key);
    if (resolved.failure) {
      failedRoots.push({ key, source: file, reason: resolved.failure });
      continue;
    }
    rootFinal.set(key, resolved.source);
    if (!rootSources.has(resolved.source)) rootSources.set(resolved.source, key);
  }

  const projector = new Projector(limits, (target, st, chain) => {
    const safe = safeTarget(target);
    if (safe === null) {
      st.loadSpecs.unresolved++;
      st.drop('loadSpec:unsafe-path');
      return false;
    }
    const key = ensureNested(safe, chain + 1, st);
    if (key === null) return false;
    nested.set(safe, key);
    return true;
  });

  const ensureNested = (target, chain, parent) => {
    let file = null;
    if (isExcluded(target)) {
      parent.loadSpecs.unresolved++;
      parent.drop('loadSpec:excluded');
      return null;
    }
    for (const candidate of [`src/${target}.ts`, `src/${target}/index.ts`]) {
      if (files.has(candidate)) {
        file = candidate;
        break;
      }
    }
    if (file === null) {
      parent.loadSpecs.unresolved++;
      parent.drop('loadSpec:missing');
      return null;
    }
    const resolved = finalSource(file, target);
    if (resolved.failure) {
      failedNested.push({ key: target, reason: resolved.failure });
      parent.loadSpecs.unresolved++;
      return null;
    }
    const existing = bySource.get(resolved.source);
    if (existing) return existing;
    if (chain > limits.maxNestedChain) {
      parent.loadSpecs.unresolved++;
      parent.drop('loadSpec:chain-too-long');
      return null;
    }
    const key = rootSources.get(resolved.source) ?? target;
    return buildAsset(key, resolved.source, chain, target) ? key : null;
  };

  // Projects one spec file into an asset. Returns false (and records why) when the file has no static Subcommand.
  const buildAsset = (key, source, chain, label) => {
    interpreter.beginAsset();
    const value = interpreter.defaultExport(source);
    if (!(value instanceof Map)) {
      const reason = value instanceof Unsupported ? `${value.kind}${value.detail ? `: ${value.detail}` : ''}` : value instanceof FnValue ? 'function-spec' : 'not-an-object';
      (roots.has(label) ? failedRoots : failedNested).push({ key: label, source, reason });
      return false;
    }
    maxChain = Math.max(maxChain, chain);
    bySource.set(source, key);
    const st = new Collector(key, source, limits);
    const entry = { key, source, chain, st, json: null, file: assetFileName(key) };
    assets.set(key, entry);
    let rootValue = value;
    if (projector.nameOf(value.get('name'), new Collector(key, source, limits)) === undefined) {
      // A spec without a usable name is still addressable by the key it was reached through.
      rootValue = new Map(value);
      rootValue.set('name', label);
      if (value.taint) rootValue.taint = value.taint;
      st.drop('root:name-from-key');
    }
    const node = projector.node('subcommand', rootValue, st, 'root', 0, chain);
    if (node === null) {
      assets.delete(key);
      bySource.delete(source);
      failedRoots.push({ key: label, source, reason: 'projection produced no node' });
      return false;
    }
    entry.json = JSON.stringify(node);
    const bytes = Buffer.byteLength(entry.json);
    if (bytes > limits.maxAssetBytes) throw new BudgetError(`${key} is ${bytes} bytes, over the per-asset limit`);
    totalBytes += bytes;
    if (totalBytes > limits.maxTotalBytes) throw new BudgetError('output exceeds the total size limit');
    entry.bytes = bytes;
    entry.names = node.name;
    return true;
  };

  for (const key of roots.keys()) {
    const source = rootFinal.get(key);
    if (source === undefined) continue;
    if (bySource.has(source)) continue;
    buildAsset(rootSources.get(source), source, 0, key);
  }

  // Commands: file-derived root names first, then aliases from the spec's own names.
  const commands = new Map();
  const aliasConflicts = [];
  for (const key of [...roots.keys()].sort(compare)) {
    const source = rootFinal.get(key);
    const assetKey = source === undefined ? undefined : bySource.get(source);
    if (assetKey !== undefined) commands.set(key, assetKey);
  }
  for (const key of [...roots.keys()].sort(compare)) {
    const assetKey = commands.get(key);
    if (assetKey === undefined) continue;
    const names = [assets.get(assetKey).names].flat().filter((n) => typeof n === 'string');
    for (const alias of names) {
      if (alias === key || /\s/.test(alias)) continue;
      if (commands.has(alias)) {
        if (commands.get(alias) !== assetKey) aliasConflicts.push({ alias, root: key, heldBy: commands.get(alias) });
        continue;
      }
      commands.set(alias, assetKey);
    }
  }

  // File names must be unique even on a case-insensitive file system.
  const seenNames = new Map();
  for (const entry of assets.values()) {
    const folded = entry.file.toLowerCase();
    if (seenNames.has(folded)) throw new ImportError(`asset file name collision: ${entry.key} and ${seenNames.get(folded)}`);
    seenNames.set(folded, entry.key);
  }

  const assetPath = (entry) => `${ASSET_DIR}/specs/${entry.file}`;
  const outputs = new Map();
  for (const entry of [...assets.values()].sort((a, b) => compare(a.file, b.file))) outputs.set(`specs/${entry.file}`, entry.json);
  outputs.set('LICENSE', license);

  const totals = {
    unsupported: new Map(), omitted: new Map(), dropped: new Map(), truncated: 0, nodes: 0,
    loadSpecs: { linked: 0, inline: 0, unresolved: 0, dynamic: 0 },
  };
  for (const { st } of assets.values()) {
    for (const [k, v] of st.unsupported) increment(totals.unsupported, k, v);
    for (const [k, v] of st.omitted) increment(totals.omitted, k, v);
    for (const [k, v] of st.dropped) increment(totals.dropped, k, v);
    totals.truncated += st.truncated;
    totals.nodes += st.nodes;
    for (const k of Object.keys(totals.loadSpecs)) totals.loadSpecs[k] += st.loadSpecs[k];
  }

  const licenseTitle = license.toString('utf8').split(/\r?\n/).find((line) => line.trim() !== '')?.trim() ?? '';
  const packageLicense = packageJson.license ?? null;
  const licenseDiscrepancy = packageLicense !== null && !licenseTitle.toUpperCase().includes(String(packageLicense).toUpperCase());
  const manifest = {
    version: SCHEMA_VERSION,
    source: {
      name: packageJson.name ?? null,
      repository: pinned?.repository ?? null,
      commit: sources.commit ?? pinned?.commit ?? null,
      packageVersion: packageJson.version ?? null,
      archive: archive ? { url: archive.url ?? null, sha256: archive.sha256, bytes: archive.bytes } : null,
      license: {
        file: `${ASSET_DIR}/LICENSE`,
        sha256: sha256(license),
        title: licenseTitle,
        packageJson: packageLicense,
        discrepancy: licenseDiscrepancy,
        note: licenseDiscrepancy
          ? 'The LICENSE file and package.json disagree; the LICENSE file text is preserved verbatim and release licensing must be reviewed.'
          : null,
      },
      parser: parser ? { name: 'typescript', version: parser.version, integrity: parser.integrity ?? null } : null,
      importer: {
        script: 'tool/import_completion_specs.mjs',
        schema: SCHEMA_VERSION,
        pinned: pinned !== null,
        exclude: excludeList,
        limits,
      },
    },
    commands: Object.fromEntries([...commands].sort(([a], [b]) => compare(a, b)).map(([name, key]) => [name, assetPath(assets.get(key))])),
    nested: Object.fromEntries(
      [...nested].sort(([a], [b]) => compare(a, b)).map(([target, key]) => [target, assetPath(assets.get(key))]),
    ),
    stats: {
      roots: roots.size,
      rootsProjected: new Set(commands.values()).size,
      rootsFailed: failedRoots.length,
      commands: commands.size,
      assets: assets.size,
      nestedRefs: nested.size,
      maxNestedChain: maxChain,
      bytes: totalBytes,
      nodes: totals.nodes,
      truncatedDescriptions: totals.truncated,
      loadSpec: totals.loadSpecs,
      unsupported: sortedObject(totals.unsupported),
      omitted: sortedObject(totals.omitted),
      dropped: sortedObject(totals.dropped),
    },
  };
  outputs.set('manifest.json', `${JSON.stringify(manifest, null, 2)}\n`);

  const referenced = new Set(bySource.keys());
  const audit = {
    schema: SCHEMA_VERSION,
    commit: manifest.source.commit,
    packageVersion: manifest.source.packageVersion,
    totals: manifest.stats,
    syntaxErrors: sortedObject(interpreter.syntaxErrors),
    failedRoots: failedRoots.sort((a, b) => compare(a.key, b.key)),
    failedNested: failedNested.sort((a, b) => compare(a.key, b.key)),
    rootConflicts,
    aliasConflicts,
    versioned: versioned.sort((a, b) => compare(a.key, b.key)),
    excludedRoots,
    unreferencedSources: [...nonRoot].filter((f) => !referenced.has(f)),
    assets: [...assets.values()]
      .sort((a, b) => compare(a.key, b.key))
      .map(({ key, source, chain, bytes, st }) => ({
        key, source, chain, bytes, nodes: st.nodes, truncated: st.truncated,
        unsupported: sortedObject(st.unsupported), omitted: sortedObject(st.omitted), dropped: sortedObject(st.dropped),
        loadSpec: st.loadSpecs, samples: st.samples,
      })),
  };
  validateOutputs(outputs);
  return { outputs, manifest, audit };
}

// ---------------------------------------------------------------------------------------------------------------
// Output invariants, shared by the importer and the tests.

const SPEC_KEYS = {
  subcommand: new Set(FIELD_ORDER.subcommand),
  option: new Set(FIELD_ORDER.option),
  arg: new Set(FIELD_ORDER.arg),
  suggestion: new Set(FIELD_ORDER.suggestion),
};

export function validateOutputs(outputs) {
  const problems = [];
  const fail = (where, message) => problems.push(`${where}: ${message}`);
  const manifestText = outputs.get('manifest.json');
  if (manifestText === undefined) throw new ImportError('manifest.json missing');
  const manifest = JSON.parse(manifestText);
  if (manifest.version !== SCHEMA_VERSION) fail('manifest', 'unexpected version');
  const specPaths = new Set([...outputs.keys()].filter((p) => p.startsWith('specs/')).map((p) => `${ASSET_DIR}/${p}`));
  const referenced = new Set();
  const checkMap = (field, map) => {
    for (const [name, assetPath] of Object.entries(map ?? {})) {
      if (typeof assetPath !== 'string' || !specPaths.has(assetPath)) fail(`manifest.${field}`, `${name} -> ${assetPath} is not an output`);
      else referenced.add(assetPath);
    }
  };
  checkMap('commands', manifest.commands);
  checkMap('nested', manifest.nested);
  for (const assetPath of specPaths) if (!referenced.has(assetPath)) fail('manifest', `${assetPath} is not referenced`);

  const isName = (v) => (typeof v === 'string' && v !== '' && !CONTROL_RE.test(v)) || (Array.isArray(v) && v.length > 1 && v.every((s) => typeof s === 'string' && s !== '' && !CONTROL_RE.test(s)));
  const strings = (v) => Array.isArray(v) && v.length > 0 && v.every((s) => typeof s === 'string' && s !== '' && !CONTROL_RE.test(s));
  const checkNode = (type, node, where) => {
    if (typeof node !== 'object' || node === null || Array.isArray(node)) return fail(where, `${type} is not an object`);
    for (const [key, value] of Object.entries(node)) {
      const at = `${where}/${key}`;
      if (!SPEC_KEYS[type].has(key)) {
        fail(at, 'field is not in the schema');
        continue;
      }
      if (value === null || value === undefined || typeof value === 'function') fail(at, 'null or function value');
      switch (key) {
        case 'name':
          if (!isName(value)) fail(at, 'invalid name');
          break;
        case 'displayName': case 'description': case 'insertValue': case 'default':
          if (typeof value !== 'string' || value === '' || CONTROL_RE.test(value)) fail(at, 'invalid string');
          break;
        case 'priority':
          if (typeof value !== 'number' || value < 0 || value > 100) fail(at, 'invalid priority');
          break;
        case 'hidden': case 'deprecated': case 'isDangerous': case 'requiresSubcommand': case 'isPersistent':
        case 'isRequired': case 'requiresEquals': case 'isOptional': case 'isVariadic': case 'isCommand':
        case 'isScript': case 'optionsCanBreakVariadicArg': case 'suggestCurrentToken':
          if (value !== true) fail(at, 'flag must be true when present');
          break;
        case 'isRepeatable':
          if (value !== true && !(Number.isInteger(value) && value >= 2)) fail(at, 'invalid isRepeatable');
          break;
        case 'requiresSeparator': case 'isModule':
          if (value !== true && !(typeof value === 'string' && value !== '')) fail(at, 'invalid value');
          break;
        case 'exclusiveOn': case 'dependsOn':
          if (!strings(value)) fail(at, 'invalid string list');
          break;
        case 'template':
          if (!(typeof value === 'string' && value !== '') && !strings(value)) fail(at, 'invalid template');
          break;
        case 'parserDirectives':
          if (typeof value !== 'object' || value === null) fail(at, 'invalid parserDirectives');
          else {
            for (const [k, v] of Object.entries(value)) {
              if (PARSER_FLAGS.has(k)) {
                if (v !== true) fail(`${at}/${k}`, 'flag must be true');
              } else if (k === 'optionArgSeparators') {
                if (!(typeof v === 'string' && v !== '') && !strings(v)) fail(`${at}/${k}`, 'invalid separators');
              } else fail(`${at}/${k}`, 'field is not in the schema');
            }
          }
          break;
        case 'loadSpec':
          if (typeof value === 'string') {
            if (manifest.nested?.[value] === undefined) fail(at, `loadSpec ${value} is not in manifest.nested`);
          } else checkNode('subcommand', value, at);
          break;
        case 'subcommands': case 'options': case 'additionalSuggestions': case 'suggestions': {
          const childType = key === 'subcommands' ? 'subcommand' : key === 'options' ? 'option' : 'suggestion';
          if (!Array.isArray(value) || value.length === 0) fail(at, 'must be a non-empty array');
          else {
            value.forEach((child, i) => {
              if (childType === 'suggestion' && typeof child === 'string') {
                if (child === '' || CONTROL_RE.test(child)) fail(`${at}/${i}`, 'invalid suggestion string');
              } else checkNode(childType, child, `${at}/${i}`);
            });
          }
          break;
        }
        case 'args':
          if (Array.isArray(value)) {
            if (value.length === 0) fail(at, 'empty args array');
            value.forEach((child, i) => checkNode('arg', child, `${at}/${i}`));
          } else checkNode('arg', value, at);
          break;
        default:
          fail(at, 'unchecked field');
      }
    }
    if (type !== 'arg' && !('name' in node)) fail(where, `${type} without a name`);
  };
  for (const [file, data] of outputs) {
    if (!file.startsWith('specs/')) continue;
    let parsed;
    try {
      parsed = JSON.parse(data);
    } catch (error) {
      fail(file, `invalid JSON: ${error.message}`);
      continue;
    }
    checkNode('subcommand', parsed, file);
  }
  if (problems.length > 0) {
    throw new ImportError(`output validation failed (${problems.length}):\n${problems.slice(0, 20).join('\n')}`);
  }
}

export function writeOutputs(outDir, outputs) {
  const specsDir = path.join(outDir, 'specs');
  mkdirSync(specsDir, { recursive: true });
  for (const name of readdirSync(specsDir)) {
    if (!name.endsWith('.json')) throw new ImportError(`unexpected file in ${specsDir}: ${name}`);
    if (!outputs.has(`specs/${name}`)) rmSync(path.join(specsDir, name));
  }
  const ordered = [...outputs.keys()].filter((p) => p !== 'manifest.json').sort(compare);
  for (const rel of ordered) writeFileSync(path.join(outDir, rel), outputs.get(rel));
  writeFileSync(path.join(outDir, 'manifest.json'), outputs.get('manifest.json'));
}

// ---------------------------------------------------------------------------------------------------------------
// CLI

function parseArgs(argv) {
  const options = { unpinned: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--unpinned') options.unpinned = true;
    else if (['--archive', '--source', '--typescript', '--out', '--audit', '--archive-sha256', '--exclude'].includes(arg)) {
      if (i + 1 >= argv.length) throw new ImportError(`${arg} needs a value`);
      options[arg.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = argv[++i];
    } else throw new ImportError(`unknown argument ${arg}`);
  }
  return options;
}

function main() {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const repo = path.resolve(here, '..');
  const options = parseArgs(process.argv.slice(2));
  if (!options.typescript || (!options.archive && !options.source) || (options.archive && options.source)) {
    throw new ImportError(
      'usage: import_completion_specs.mjs (--archive <tar.gz> | --source <dir>) --typescript <dir> [--out <dir>] [--audit <file>] [--archive-sha256 <hex>] [--exclude <root,root>] [--unpinned]',
    );
  }
  const pinned = options.unpinned ? null : PINNED;
  const parser = loadTypescript(options.typescript, { pinned: !options.unpinned });
  let sources;
  let archive = null;
  if (options.archive) {
    const bytes = readFileSync(options.archive);
    const digest = sha256(bytes);
    if (options.archiveSha256 && options.archiveSha256.toLowerCase() !== digest) throw new ImportError('archive SHA-256 mismatch');
    sources = readTarGz(bytes, { expectedCommit: pinned?.commit ?? null });
    archive = { url: pinned?.archiveUrl ?? null, sha256: digest, bytes: bytes.length };
  } else {
    sources = readSourceDirectory(options.source);
  }
  const result = importSpecs({
    sources,
    ts: parser.ts,
    pinned,
    archive,
    parser: { version: parser.version, integrity: parser.version === PINNED.typescriptVersion ? PINNED.typescriptIntegrity : null },
    exclude: (options.exclude ?? '').split(',').filter((e) => e !== ''),
  });
  const outDir = path.resolve(options.out ?? path.join(repo, ASSET_DIR));
  writeOutputs(outDir, result.outputs);
  const auditPath = path.resolve(options.audit ?? path.join(here, 'import_completion_specs.audit.json'));
  writeFileSync(auditPath, `${JSON.stringify(result.audit, null, 1)}\n`);
  const { stats } = result.manifest;
  process.stdout.write(
    `roots ${stats.rootsProjected}/${stats.roots} (failed ${stats.rootsFailed}), commands ${stats.commands}, assets ${stats.assets}, ` +
      `nested refs ${stats.nestedRefs}, ${stats.bytes} bytes, ${stats.nodes} nodes\n`,
  );
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${error instanceof ImportError ? '' : error.stack ? `${error.stack}\n` : ''}error: ${error.message}\n`);
    process.exitCode = 1;
  }
}
