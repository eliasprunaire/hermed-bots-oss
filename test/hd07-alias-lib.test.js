"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const {
  chmodSync,
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readlinkSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const LIB = join(
  __dirname,
  "..",
  "docs",
  "spike",
  "hd07-instruments",
  "lib.sh",
);

const ENDPOINT_STUB = `#!/usr/bin/env bash
cat > /dev/null
exit 0
`;

// trash déplace vers un dossier jetable : aucune suppression réelle dans le test
const TRASH_STUB = `#!/usr/bin/env bash
mkdir -p "$TRASHED"
mv "$@" "$TRASHED/"
`;

const HAVE_KEYGEN = existsSync("/usr/bin/ssh-keygen");
const SKIP = HAVE_KEYGEN ? false : "pas de /usr/bin/ssh-keygen";

// monte un HOME jetable, exécute `script` après avoir sourcé lib.sh, rend le dossier, la sortie et les codes
function lane(script, prepare) {
  const dir = mkdtempSync(join(tmpdir(), "hd07-alias-lib-"));
  const here = join(dir, "repo", "docs", "spike", "hd07-instruments");
  const home = join(dir, "home");
  const bin = join(dir, "bin");
  mkdirSync(here, { recursive: true });
  mkdirSync(join(home, ".ssh"), { recursive: true });
  mkdirSync(bin);
  mkdirSync(join(dir, "work"));
  copyFileSync(LIB, join(here, "lib.sh"));
  writeFileSync(join(here, "hv-ssh-endpoint.sh"), ENDPOINT_STUB, { mode: 0o755 });
  writeFileSync(join(bin, "trash"), TRASH_STUB, { mode: 0o755 });
  const ctx = {
    dir,
    home,
    config: join(home, ".ssh", "config"),
    keydir: join(dir, "work", "hd07-key"),
    trashed: join(dir, "trashed"),
  };
  if (prepare) prepare(ctx);
  const result = spawnSync(
    "bash",
    [
      "-c",
      `. "${join(here, "lib.sh")}"; ${script}`,
    ],
    {
      encoding: "utf8",
      env: {
        PATH: `${bin}:${process.env.PATH}`,
        HOME: home,
        HV_WORK: join(dir, "work"),
        TRASHED: ctx.trashed,
      },
    },
  );
  return { ...ctx, result };
}

function done(run) {
  // les droits d'écriture reviennent avant le nettoyage du dossier jetable
  for (const file of [run.config, join(run.dir, "dotfiles", "ssh_config")]) {
    try {
      chmodSync(file, 0o644);
    } catch {
      // le fichier n'existe pas dans ce cas
    }
  }
  rmSync(run.dir, { recursive: true, force: true });
}

const ORIGINAL = "Host lab\n  HostName lab.invalid\n  User operator"; // sans newline final

test("drop_alias restores a regular config byte for byte and removes the keys", { skip: SKIP }, () => {
  const run = lane(
    'new_alias; echo "new=$?"; drop_alias; echo "drop=$?"',
    ({ config }) => writeFileSync(config, ORIGINAL),
  );
  try {
    assert.match(run.result.stdout, /new=0\ndrop=0\n/);
    assert.equal(readFileSync(run.config, "utf8"), ORIGINAL);
    assert.equal(lstatSync(run.config).isSymbolicLink(), false);
    assert.equal(existsSync(run.keydir), false);
  } finally {
    done(run);
  }
});

test("drop_alias keeps a symbolic-link config a link and restores its target", { skip: SKIP }, () => {
  let target;
  const run = lane(
    'new_alias; echo "new=$?"; drop_alias; echo "drop=$?"',
    ({ dir, config }) => {
      mkdirSync(join(dir, "dotfiles"));
      target = join(dir, "dotfiles", "ssh_config");
      writeFileSync(target, ORIGINAL);
      symlinkSync(target, config);
    },
  );
  try {
    assert.match(run.result.stdout, /new=0\ndrop=0\n/);
    assert.equal(lstatSync(run.config).isSymbolicLink(), true);
    assert.equal(readlinkSync(run.config), target);
    assert.equal(readFileSync(target, "utf8"), ORIGINAL);
    assert.equal(existsSync(run.keydir), false);
  } finally {
    done(run);
  }
});

test("drop_alias removes a config that new_alias created", { skip: SKIP }, () => {
  const run = lane('new_alias; echo "new=$?"; drop_alias; echo "drop=$?"');
  try {
    assert.match(run.result.stdout, /new=0\ndrop=0\n/);
    assert.equal(existsSync(run.config), false);
    assert.equal(existsSync(run.keydir), false);
  } finally {
    done(run);
  }
});

test(
  "drop_alias fails loudly and keeps the keys when it cannot clean the config",
  { skip: SKIP || (process.getuid?.() === 0 && "root écrit malgré chmod") },
  () => {
    const run = lane(
      'new_alias; echo "new=$?"; chmod 444 "$(readlink "$HOME/.ssh/config")"; drop_alias; echo "drop=$?"',
      ({ dir, config }) => {
        mkdirSync(join(dir, "dotfiles"));
        const target = join(dir, "dotfiles", "ssh_config");
        writeFileSync(target, ORIGINAL);
        symlinkSync(target, config);
      },
    );
    try {
      assert.match(run.result.stdout, /new=0\ndrop=1\n/);
      assert.match(run.result.stderr, /hv-hd07/);
      // le bloc Include reste dans la config : les clés qu'il nomme restent aussi
      assert.equal(existsSync(join(run.keydir, "config")), true);
      assert.match(readFileSync(run.config, "utf8"), /^# hv-hd07 begin\n/);
    } finally {
      done(run);
    }
  },
);

test("new_alias refuses a dangling symbolic-link config before writing anything", { skip: SKIP }, () => {
  const run = lane('new_alias; echo "new=$?"', ({ dir, config }) => {
    symlinkSync(join(dir, "missing", "ssh_config"), config);
  });
  try {
    assert.match(run.result.stdout, /new=1\n/);
    assert.match(run.result.stderr, /hv-hd07/);
    assert.equal(existsSync(run.keydir), false);
    assert.equal(existsSync(join(run.dir, "missing")), false);
  } finally {
    done(run);
  }
});
