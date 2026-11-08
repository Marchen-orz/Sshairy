// node --test tool/test/   (no network)
// Needs SSHAIRY_TYPESCRIPT_DIR=<extracted typescript package> for the parts that parse TypeScript; without it those
// tests are reported as skipped, not passed. The tar and directory readers are tested without the parser.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';
import {
  assetFileName,
  BudgetError,
  ImportError,
  importSpecs,
  LIMITS,
  loadTypescript,
  PINNED,
  readSourceDirectory,
  readTarGz,
  validateOutputs,
  writeOutputs,
} from '../import_completion_specs.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.join(here, '..', 'import_completion_specs.mjs');
const FIXTURE = path.join(here, 'fixtures', 'completion_specs');
const TS_DIR = process.env.SSHAIRY_TYPESCRIPT_DIR;
const needsParser = TS_DIR ? false : 'set SSHAIRY_TYPESCRIPT_DIR to an extracted typescript package';
const parser = TS_DIR ? loadTypescript(TS_DIR, { pinned: false }) : null;

const temp = () => mkdtempSync(path.join(os.tmpdir(), 'sshairy-specs-test-'));
const memory = (files) => ({
  commit: null,
  files: new Map(
    Object.entries({ LICENSE: 'MIT License\n', 'package.json': '{"name":"x","version":"1","license":"MIT"}', ...files }).map(
      ([name, text]) => [name, Buffer.from(text)],
    ),
  ),
});
const run = (sources, extra = {}) => importSpecs({ sources, ts: parser.ts, parser: { version: parser.version }, ...extra });
const spec = (result, file) => JSON.parse(result.outputs.get(`specs/${file}.json`));
const fixtureResult = (extra) => run(readSourceDirectory(FIXTURE), extra);

// --- tar fixtures -------------------------------------------------------------------------------------------------

function tarHeader({ name, type = '0', size = 0, linkname = '' }) {
  const header = Buffer.alloc(512);
  header.write(name, 0, 100, 'utf8');
  header.write('0000644\0', 100);
  header.write('0000000\0', 108);
  header.write('0000000\0', 116);
  header.write(`${size.toString(8).padStart(11, '0')}\0`, 124);
  header.write('00000000000\0', 136);
  header.write('        ', 148);
  header.write(type, 156);
  header.write(linkname, 157, 100, 'utf8');
  header.write('ustar\0', 257);
  header.write('00', 263);
  let sum = 0;
  for (const byte of header) sum += byte;
  header.write(`${sum.toString(8).padStart(6, '0')}\0 `, 148);
  return header;
}

function tarEntry(entry) {
  const data = Buffer.from(entry.data ?? '');
  const blocks = Buffer.alloc(Math.ceil(data.length / 512) * 512);
  data.copy(blocks);
  return Buffer.concat([tarHeader({ ...entry, size: data.length }), blocks]);
}

// A pax record starts with its own total length in decimal, so iterate until the length is self-consistent.
function paxComment(commit) {
  const body = ` comment=${commit}\n`;
  let length = body.length;
  while (`${length}${body}`.length !== length) length = `${length}${body}`.length;
  return `${length}${body}`;
}

function makeTar(entries, { commit = PINNED.commit, top = `autocomplete-${PINNED.commit}` } = {}) {
  const parts = [];
  if (commit) parts.push(tarEntry({ name: 'pax_global_header', type: 'g', data: paxComment(commit) }));
  for (const entry of entries) parts.push(tarEntry({ ...entry, name: entry.raw ? entry.name : `${top}/${entry.name}` }));
  parts.push(Buffer.alloc(1024));
  return Buffer.concat(parts);
}

const gz = (tar) => gzipSync(tar);

describe('tar reader', () => {
  const good = [
    { name: '', type: '5' },
    { name: 'LICENSE', data: 'MIT License\n' },
    { name: 'package.json', data: '{}' },
    { name: 'src/a.ts', data: 'export default {}' },
    { name: 'src/types.d.ts', data: 'declare const x: 1' },
    { name: 'icons/logo.png', data: 'png' },
    { name: 'src/link.ts', type: '2', linkname: '/etc/passwd' },
  ];

  it('keeps only whitelisted regular files and verifies the pax commit', () => {
    const result = readTarGz(gz(makeTar(good)), { expectedCommit: PINNED.commit });
    assert.deepEqual([...result.files.keys()].sort(), ['LICENSE', 'package.json', 'src/a.ts']);
    assert.equal(result.commit, PINNED.commit);
    assert.equal(result.ignored, 3, 'declaration file, png and symlink are ignored, never followed');
  });

  it('refuses unsafe paths, mixed roots and duplicates', () => {
    const top = `autocomplete-${PINNED.commit}`;
    for (const name of [`${top}/../evil.ts`, `${top}/src/../../evil.ts`, 'C:/evil.ts', `${top}/src\\evil.ts`, '/etc/passwd']) {
      const tar = makeTar([{ name, raw: true, data: 'x' }], {});
      assert.throws(() => readTarGz(gz(tar)), /unsafe path/, name);
    }
    const mixed = makeTar([{ name: 'a/src/x.ts', raw: true, data: '1' }, { name: 'b/src/y.ts', raw: true, data: '2' }]);
    assert.throws(() => readTarGz(gz(mixed)), /more than one top-level/);
    const dup = makeTar([{ name: 'src/x.ts', data: '1' }, { name: 'src/x.ts', data: '2' }]);
    assert.throws(() => readTarGz(gz(dup)), /duplicate source path/);
  });

  it('refuses a wrong commit, a corrupt header, truncation and oversize input', () => {
    assert.throws(() => readTarGz(gz(makeTar(good, { commit: 'f'.repeat(40) })), { expectedCommit: PINNED.commit }), /does not match/);
    assert.throws(() => readTarGz(gz(makeTar(good, { commit: null })), { expectedCommit: PINNED.commit }), /does not match/);
    const corrupt = makeTar(good);
    corrupt[1024 + 3] ^= 0x01;
    assert.throws(() => readTarGz(gz(corrupt)), /checksum/);
    const tar = makeTar(good);
    assert.throws(() => readTarGz(gz(tar.subarray(0, 1100))), /truncated|checksum/);
    assert.throws(() => readTarGz(Buffer.from('not gzip')), /cannot decompress/);
    assert.throws(() => readTarGz(gz(makeTar(good)), { limits: { ...LIMITS, maxUnpackedBytes: 1024 } }), /cannot decompress/);
    assert.throws(() => readTarGz(gz(makeTar(good)), { limits: { ...LIMITS, maxArchiveBytes: 10 } }), BudgetError);
    assert.throws(() => readTarGz(gz(makeTar(good)), { limits: { ...LIMITS, maxSourceFileBytes: 4 } }), BudgetError);
    assert.throws(() => readTarGz(gz(makeTar(good)), { limits: { ...LIMITS, maxEntries: 2 } }), BudgetError);
  });
});

describe('directory reader', () => {
  it('reads the same whitelist and refuses symbolic links', () => {
    const root = temp();
    try {
      mkdirSync(path.join(root, 'src', 'sub'), { recursive: true });
      mkdirSync(path.join(root, 'icons'));
      writeFileSync(path.join(root, 'LICENSE'), 'MIT License\n');
      writeFileSync(path.join(root, 'src', 'a.ts'), 'x');
      writeFileSync(path.join(root, 'src', 'sub', 'b.ts'), 'y');
      writeFileSync(path.join(root, 'src', 'a.d.ts'), 'z');
      writeFileSync(path.join(root, 'icons', 'logo.png'), 'p');
      const result = readSourceDirectory(root);
      assert.deepEqual([...result.files.keys()].sort(), ['LICENSE', 'src/a.ts', 'src/sub/b.ts']);
      let linked = true;
      try {
        symlinkSync(path.join(root, 'LICENSE'), path.join(root, 'src', 'link.ts'));
      } catch {
        linked = false; // Windows needs a privilege for symlinks; the archive path above covers link entries.
      }
      if (linked) assert.throws(() => readSourceDirectory(root), /symbolic link/);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});

describe('typescript loader', () => {
  it('requires the pinned typescript package', () => {
    const dir = temp();
    try {
      writeFileSync(path.join(dir, 'package.json'), '{"name":"left-pad","version":"1.0.0"}');
      assert.throws(() => loadTypescript(dir), /must point at the typescript package/);
      writeFileSync(path.join(dir, 'package.json'), '{"name":"typescript","version":"1.0.0"}');
      assert.throws(() => loadTypescript(dir), /required/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe('asset names', () => {
  it('flattens, encodes and avoids Windows reserved names', () => {
    assert.equal(assetFileName('git'), 'git.json');
    assert.equal(assetFileName('@scope/pkg'), '@scope__pkg.json');
    assert.equal(assetFileName('aws/ec2'), 'aws__ec2.json');
    assert.equal(assetFileName('a b'), 'a_x20_b.json');
    assert.equal(assetFileName('con'), '_r_con.json');
    assert.equal(assetFileName('COM1.x'), '_r_COM1.x.json');
    assert.equal(assetFileName('-'), '-.json');
  });
});

describe('fixture projection', { skip: needsParser }, () => {
  const result = fixtureResult();
  const { manifest, audit } = result;

  it('indexes roots, aliases and nested specs', () => {
    assert.deepEqual(Object.keys(manifest.commands), [
      '@scope/pkg', 'al', 'built', 'ctrl', 'cyclic', 'direct', 'nameless', 'reexport', 'tl', 'tool', 'versioned',
    ]);
    assert.equal(manifest.commands.tl, manifest.commands.tool);
    assert.equal(manifest.commands['@scope/pkg'], 'assets/completions/specs/@scope__pkg.json');
    assert.deepEqual(Object.keys(manifest.nested), ['tool', 'tool/cycle', 'tool/deeper', 'tool/sub']);
    assert.equal(manifest.nested.tool, manifest.commands.tool, 'a loadSpec back to a root reuses the root asset');
    assert.equal(manifest.stats.maxNestedChain, 2);
    assert.deepEqual(audit.aliasConflicts, [{ alias: 'al', root: 'tool', heldBy: 'al' }]);
    assert.equal(manifest.commands.al, 'assets/completions/specs/al.json');
  });

  it('reports roots that cannot be read statically instead of dropping them silently', () => {
    const failed = Object.fromEntries(audit.failedRoots.map((f) => [f.key, f.reason]));
    assert.deepEqual(failed, {
      broken: 'function-spec',
      more: 'missing-export: default',
      shared: 'missing-export: default',
    });
    assert.equal(manifest.stats.rootsFailed, 3);
    assert.ok(!('broken' in manifest.commands));
    assert.deepEqual(spec(result, 'built'), {name: 'built'});
  });

  it('projects the main fixture spec', () => {
    const tool = spec(result, 'tool');
    assert.deepEqual(Object.keys(tool), ['name', 'description', 'parserDirectives', 'subcommands', 'options', 'additionalSuggestions']);
    assert.deepEqual(tool.name, ['tool', 'tl', 'al']);
    assert.equal(tool.description, 'A fixture tool for the importer');
    assert.deepEqual(tool.parserDirectives, { flagsArePosixNoncompliant: true, optionArgSeparators: '=' });
    assert.deepEqual(tool.additionalSuggestions, ['extra', { name: 'other', description: 'Other' }]);
    assert.deepEqual(tool.options, [
      { name: ['-v', '--verbose'], description: 'Print more output', isRepeatable: 3 },
      { name: ['-h', '--help'], description: 'Show help' },
      { name: '--version', description: 'Show version', isPersistent: true },
      { name: '--extra', description: 'Comes through a re-export', isRequired: true },
      { name: '--namespaced', requiresEquals: true },
      {
        name: '--format',
        requiresSeparator: '=',
        exclusiveOn: ['--json'],
        dependsOn: ['--output'],
        args: {
          name: 'format',
          default: 'json',
          suggestions: [
            'bash',
            'zsh',
            { name: 'json', description: 'JSON', priority: 90 },
            'yaml',
            { name: ['text', 'txt'], insertValue: 'text {cursor}' },
          ],
        },
      },
    ]);
    assert.deepEqual(tool.subcommands, [
      {
        name: 'run',
        description: 'Run it',
        loadSpec: 'tool/sub',
        args: [{ name: 'script', isVariadic: true, template: ['filepaths', 'folders'] }, { name: 'version', isOptional: true }],
      },
      { name: 'dyn', args: { isOptional: true } },
      { name: 'cycle', loadSpec: 'tool/cycle' },
      { name: 'gone' },
      { name: 'danger', insertValue: 'danger {cursor}', priority: 20, hidden: true, deprecated: true, isDangerous: true },
      {
        name: 'inline',
        args: {
          name: 'team',
          isDangerous: true,
          loadSpec: { name: 'team', subcommands: [{ name: 'members' }] },
        },
      },
      { name: 'tpl', description: 'static value 2' },
      { name: 'nested-array', args: [{ name: 'kept', template: 'history' }] },
    ]);
    assert.deepEqual(Object.keys(tool.options[5]), ['name', 'requiresSeparator', 'exclusiveOn', 'dependsOn', 'args']);
  });

  it('resolves nested specs and cycles through the manifest', () => {
    assert.deepEqual(spec(result, 'tool__sub'), {
      name: 'sub',
      description: 'Nested spec reached through loadSpec',
      subcommands: [{ name: 'deeper', loadSpec: 'tool/deeper' }],
      options: [{ name: '--depth', args: { name: 'n' } }],
    });
    assert.deepEqual(spec(result, 'tool__cycle'), { name: 'cycle', subcommands: [{ name: 'back', loadSpec: 'tool' }] });
    assert.deepEqual(spec(result, 'tool__deeper'), { name: 'deeper', options: [{ name: '--deepest' }] });
  });

  it('omits functions, generators and icons and counts each of them', () => {
    const { omitted, unsupported, dropped, loadSpec } = manifest.stats;
    assert.equal(omitted.icon, 2);
    assert.equal(omitted.generators, 2);
    assert.equal(omitted.generateSpec, 1);
    assert.equal(omitted['loadSpec:function'], 1);
    assert.equal(omitted['parserDirectives.unknownDirective'], 1);
    assert.deepEqual(unsupported, { call: 1, cycle: 1 });
    assert.equal(dropped['subcommand:no-name'], 2);
    assert.equal(dropped['loadSpec:missing'], 1);
    assert.equal(dropped['args:not-object'], 1);
    assert.deepEqual(loadSpec, { linked: 4, inline: 1, unresolved: 1, dynamic: 1 });
    const toolAudit = audit.assets.find((a) => a.key === 'tool');
    assert.deepEqual(toolAudit.samples.map((s) => [s.kind, s.detail, s.path]), [['call', 'makeOptions', 'tool']]);
    for (const text of [...result.outputs].filter(([k]) => k.startsWith('specs/')).map(([, v]) => v)) {
      assert.ok(!/"(icon|generators|generateSpec|postProcess|script|execute)":/.test(text));
    }
  });

  it('tolerates cycles, unsupported elements and concat', () => {
    const cyclic = spec(result, 'cyclic');
    assert.deepEqual(cyclic.options, [{ name: '--a', args: { name: 'b' } }, { name: '--ok' }]);
    assert.deepEqual(cyclic.subcommands, [{ name: 'base' }, { name: 'added' }, { name: 'single' }]);
  });

  it('cleans descriptions and drops control characters from insert values', () => {
    const ctrl = spec(result, 'ctrl');
    assert.ok(ctrl.description.length <= LIMITS.descriptionChars, String(ctrl.description.length));
    assert.ok(ctrl.description.endsWith('…'));
    assert.ok(!/\s{2}|[\n\t]/.test(ctrl.description));
    assert.ok(ctrl.description.startsWith('A deliberately long description that keeps going'));
    assert.deepEqual(ctrl.options, [{ name: '--write', args: { suggestions: ['line', 'plain'] } }]);
    assert.equal(audit.assets.find((a) => a.key === 'ctrl').truncated, 1);
    assert.equal(manifest.stats.dropped['insertValue:control-chars'], 1);
    assert.equal(manifest.stats.dropped['suggestion:no-name'], 1);
    assert.equal(manifest.stats.dropped['suggestion:invalid-string'], 1);
  });

  it('handles export forms, scoped roots, nameless roots and versioned specs', () => {
    assert.deepEqual(spec(result, 'direct'), { name: 'direct', description: 'Anonymous default export' });
    assert.deepEqual(spec(result, 'reexport'), { name: 'reexport', description: 'Exported under an alias' });
    assert.deepEqual(spec(result, '@scope__pkg'), { name: '@scope/pkg', description: 'A scoped root', subcommands: [{ name: 'go', description: 'Go' }] });
    assert.deepEqual(spec(result, 'nameless'), {
      name: 'nameless',
      description: 'A root without a name falls back to its key',
      options: [{ name: '--only' }],
    });
    assert.equal(manifest.stats.dropped['root:name-from-key'], 1);
    assert.deepEqual(spec(result, 'versioned'), { name: 'versioned', description: 'newest by numeric comparison' });
    assert.deepEqual(audit.versioned, [
      {
        key: 'versioned',
        name: 'versioned',
        versions: ['1.0.0', '2.0.0', '10.0.0'],
        chosen: '10.0.0',
        source: 'src/versioned/10.0.0.ts',
      },
    ]);
    assert.deepEqual(audit.unreferencedSources, ['src/old/unreferenced.ts', 'src/versioned/1.0.0.ts', 'src/versioned/2.0.0.ts']);
  });

  it('records provenance and keeps the license text byte for byte', () => {
    const license = readFileSync(path.join(FIXTURE, 'LICENSE'));
    assert.ok(Buffer.compare(result.outputs.get('LICENSE'), license) === 0);
    assert.equal(manifest.source.license.sha256.length, 64);
    assert.equal(manifest.source.license.title, 'MIT License');
    assert.equal(manifest.source.license.packageJson, 'ISC');
    assert.equal(manifest.source.license.discrepancy, true);
    assert.match(manifest.source.license.note, /disagree/);
    assert.equal(manifest.source.parser.version, parser.version);
    assert.equal(manifest.source.archive, null);
    assert.equal(manifest.version, 1);
  });

  it('is deterministic', () => {
    const again = fixtureResult();
    assert.deepEqual([...again.outputs.keys()], [...result.outputs.keys()]);
    for (const [key, value] of result.outputs) assert.ok(Buffer.compare(Buffer.from(value), Buffer.from(again.outputs.get(key))) === 0, key);
    assert.deepEqual(again.audit, audit);
  });

  it('enforces the nested chain limit and the exclude list', () => {
    const shallow = fixtureResult({ limits: { ...LIMITS, maxNestedChain: 1 } });
    assert.ok(!('tool/deeper' in shallow.manifest.nested));
    assert.deepEqual(spec(shallow, 'tool__sub').subcommands, [{ name: 'deeper' }]);
    assert.equal(shallow.manifest.stats.dropped['loadSpec:chain-too-long'], 1);
    const excluded = fixtureResult({ exclude: ['tool'] });
    assert.ok(!('tool' in excluded.manifest.commands) && !('tl' in excluded.manifest.commands));
    assert.deepEqual(excluded.manifest.nested, {});
    assert.deepEqual(excluded.audit.excludedRoots, ['tool']);
    assert.deepEqual(excluded.manifest.source.importer.exclude, ['tool']);
  });

  it('passes the shared output invariants and rejects tampered output', () => {
    validateOutputs(result.outputs);
    const tamper = (mutate) => {
      const outputs = new Map(result.outputs);
      mutate(outputs);
      return outputs;
    };
    const edit = (file, change) => (outputs) => {
      const node = JSON.parse(outputs.get(`specs/${file}.json`));
      change(node);
      outputs.set(`specs/${file}.json`, JSON.stringify(node));
    };
    assert.throws(() => validateOutputs(tamper(edit('tool', (n) => { n.icon = 'fig://x'; }))), /not in the schema/);
    assert.throws(() => validateOutputs(tamper(edit('tool', (n) => { n.options[0].isRepeatable = false; }))), /invalid isRepeatable/);
    assert.throws(() => validateOutputs(tamper(edit('tool', (n) => { n.subcommands[0].loadSpec = 'nowhere'; }))), /not in manifest.nested/);
    assert.throws(() => validateOutputs(tamper(edit('tool', (n) => { n.options.push({ description: 'nameless' }); }))), /without a name/);
    assert.throws(() => validateOutputs(tamper(edit('tool', (n) => { n.subcommands = []; }))), /non-empty array/);
    assert.throws(() => validateOutputs(tamper((o) => o.set('specs/extra.json', '{"name":"x"}'))), /not referenced/);
    assert.throws(() => validateOutputs(tamper((o) => o.set('specs/ctrl.json', '{"name":'))), /invalid JSON/);
    assert.throws(() => validateOutputs(tamper((o) => o.delete('specs/direct.json'))), /not an output/);
  });
});

describe('interpreter edge cases', { skip: needsParser }, () => {
  it('fails on a case-insensitive file name collision', () => {
    const sources = memory({ 'src/Foo.ts': 'export default { name: "Foo" }', 'src/foo.ts': 'export default { name: "foo" }' });
    assert.throws(() => run(sources), /collision/);
  });

  it('keeps Windows reserved names out of file names', () => {
    const result = run(memory({ 'src/con.ts': 'export default { name: "con" }' }));
    assert.equal(result.manifest.commands.con, 'assets/completions/specs/_r_con.json');
  });

  it('rejects unsafe loadSpec targets and reports them', () => {
    const targets = ['../x', '/abs', 'a\\\\b', 'a//b', './x'];
    const subs = targets.map((t, i) => `{ name: "s${i}", loadSpec: "${t}" }`).join(',');
    const result = run(memory({ 'src/t.ts': `export default { name: "t", subcommands: [${subs}] }` }));
    assert.deepEqual(spec(result, 't').subcommands.map((s) => s.name), targets.map((_, i) => `s${i}`));
    assert.ok(spec(result, 't').subcommands.every((s) => !('loadSpec' in s)));
    assert.equal(result.manifest.stats.dropped['loadSpec:unsafe-path'], targets.length);
    assert.deepEqual(result.manifest.nested, {});
  });

  it('reports external imports and unsupported expressions where they are used', () => {
    const result = run(
      memory({
        'src/ext.ts': [
          'import { x } from "yaml";',
          'import { missing } from "./nowhere";',
          'const list = [1, 2].map((n) => n);',
          'export default { name: "ext", description: x, options: [{ name: "--m", description: missing }, ...list, new Date(), `${process.argv}`, a ? 1 : 2] };',
        ].join('\n'),
      }),
    );
    const kinds = result.manifest.stats.unsupported;
    assert.equal(kinds['external-import'], 1);
    assert.equal(kinds['import-missing'], 1);
    assert.ok(kinds.NewExpression >= 1);
    assert.deepEqual(spec(result, 'ext'), { name: 'ext', options: [{ name: '--m' }] });
  });

  it('honours the import depth limit and star exports', () => {
    const files = {
      'src/c.ts': 'export default { name: "c", description: a1 }; import { a1 } from "./lib/a1";',
      'src/lib/a1.ts': 'import { a2 } from "./a2"; export const a1 = a2;',
      'src/lib/a2.ts': 'import { a3 } from "./a3"; export const a2 = a3;',
      'src/lib/a3.ts': 'export * from "./a4";',
      'src/lib/a4.ts': 'export const a3 = "deep";',
    };
    assert.equal(spec(run(memory(files)), 'c').description, 'deep');
    const limited = run(memory(files), { limits: { ...LIMITS, maxImportDepth: 2 } });
    assert.equal(limited.manifest.stats.unsupported['import-too-deep'], 1);
    assert.equal(spec(limited, 'c').description, undefined);
  });

  it('fails loudly when a budget is exceeded', () => {
    const sources = readSourceDirectory(FIXTURE);
    assert.throws(() => run(sources, { limits: { ...LIMITS, maxAssetBytes: 100 } }), BudgetError);
    assert.throws(() => run(sources, { limits: { ...LIMITS, maxTotalBytes: 1000 } }), BudgetError);
    assert.throws(() => run(sources, { limits: { ...LIMITS, maxNodesPerAsset: 3 } }), BudgetError);
    assert.throws(() => run(sources, { limits: { ...LIMITS, maxEvalStepsPerAsset: 10 } }), BudgetError);
  });

  it('requires the license and the pinned package version', () => {
    const noLicense = memory({ 'src/a.ts': 'export default { name: "a" }' });
    noLicense.files.delete('LICENSE');
    assert.throws(() => run(noLicense), /LICENSE is missing/);
    assert.throws(
      () => run(memory({ 'src/a.ts': 'export default { name: "a" }' }), { pinned: PINNED }),
      (error) => error instanceof ImportError && /does not match/.test(error.message),
    );
  });

  it('records syntax errors without evaluating anything', () => {
    const result = run(memory({ 'src/bad.ts': 'export default { name: "bad", options: [ { name: } ] };' }));
    assert.ok(result.audit.syntaxErrors['src/bad.ts'] > 0);
  });
});

describe('writing and the command line', { skip: needsParser }, () => {
  it('replaces stale spec files, refuses foreign files and writes the manifest last', () => {
    const out = temp();
    try {
      const result = fixtureResult();
      mkdirSync(path.join(out, 'specs'));
      writeFileSync(path.join(out, 'specs', 'stale.json'), '{}');
      writeOutputs(out, result.outputs);
      const written = readdirSync(path.join(out, 'specs')).sort();
      assert.ok(!written.includes('stale.json'));
      assert.deepEqual(written, [...result.outputs.keys()].filter((k) => k.startsWith('specs/')).map((k) => k.slice(6)).sort());
      assert.deepEqual(JSON.parse(readFileSync(path.join(out, 'manifest.json'), 'utf8')).commands, result.manifest.commands);
      writeFileSync(path.join(out, 'specs', 'notes.txt'), 'x');
      assert.throws(() => writeOutputs(out, result.outputs), /unexpected file/);
    } finally {
      rmSync(out, { recursive: true, force: true });
    }
  });

  it('runs end to end from another working directory', () => {
    const out = temp();
    const cwd = temp();
    try {
      const args = [SCRIPT, '--source', FIXTURE, '--typescript', TS_DIR, '--unpinned', '--out', path.join(out, 'assets'), '--audit', path.join(out, 'audit.json')];
      const ok = spawnSync(process.execPath, args, { cwd, encoding: 'utf8' });
      assert.equal(ok.status, 0, ok.stderr);
      assert.match(ok.stdout, /roots 10\/13 \(failed 3\)/);
      const manifest = JSON.parse(readFileSync(path.join(out, 'assets', 'manifest.json'), 'utf8'));
      assert.equal(manifest.source.importer.pinned, false);
      assert.equal(JSON.parse(readFileSync(path.join(out, 'audit.json'), 'utf8')).failedRoots.length, 3);
      const usage = spawnSync(process.execPath, [SCRIPT], { cwd, encoding: 'utf8' });
      assert.equal(usage.status, 1);
      assert.match(usage.stderr, /usage/);
      const pinned = spawnSync(process.execPath, args.filter((a) => a !== '--unpinned'), { cwd, encoding: 'utf8' });
      assert.equal(pinned.status, 1, 'a fixture is not the pinned upstream source');
    } finally {
      rmSync(out, { recursive: true, force: true });
      rmSync(cwd, { recursive: true, force: true });
    }
  });
});
