#!/usr/bin/env python3
"""Strážca pred GitHubom — repo je VEREJNÉ (appcast/Sparkle), nič citlivé doň nesmie ísť.

Spúšťa ho git pre-push hook (scripts/install-git-hooks.sh) aj release.sh. Pri akomkoľvek
náleze push ZASTAVÍ (exit 1). Nič sa neobchádza: žiadne --no-verify; falošný poplach sa
rieši úpravou tohto súboru v samostatnom commite, nikdy nie preskočením kontroly.

Režimy:
  github-guard.py --pre-push        (stdin od gitu: <lref> <lsha> <rref> <rsha>)
  github-guard.py --range A..B      commity v rozsahu
  github-guard.py --history         celá história (audit)
  github-guard.py --bundle PATH     zostavená .app / .zip pred uploadom
Nálezy vypisuje len maskované (prvé 4 znaky), aby sa tajomstvo neobjavilo v termináli/logu.
"""
import fnmatch, re, subprocess, sys, zipfile

# 1) Čo SMIE byť v repe — všetko ostatné je zablokované (nový typ súboru = vedomé rozhodnutie
#    a úprava tohto zoznamu, nie tichý push).
ALLOWED = [
    "Sources/OsobnyPomocnik/*.swift", "Sources/OsobnyPomocnik/*/*.swift",
    "Sources/OsobnyPomocnik/*/*/*.swift",
    "Sources/OsobnyPomocnik/Resources/AppIcon.icns",
    "Sources/OsobnyPomocnik/Resources/MenuBarIcon*.png",
    "Sources/OsobnyPomocnik/Resources/Info.plist",
    "Sources/OsobnyPomocnik/Resources/Fonts/*.ttf",
    "Sources/OsobnyPomocnik/Resources/Fonts/OFL-*.txt",
    "scripts/*.sh", "scripts/*.swift", "scripts/github-guard.py",
    ".gitignore", "Makefile", "Package.swift", "Package.resolved", "models.json",
    "OsobnyPomocnik.entitlements", "build-app.sh", "release.sh", "appcast.xml",
    "README.md", "NAVOD.md", "CHANGELOG.md",
    "Ozvena-*.txt", "OsobnyPomocnik-*.txt",
]
# 2) Čo NIKDY — aj keby to niekto pridal do ALLOWED omylom (interné poznámky, prístupy, dáta).
FORBIDDEN = [
    "CLAUDE.md", "*/CLAUDE.md", "ROADMAP.md", "Vyvoj/*", ".claude/*", ".mcp.json",
    "*.env", ".env*", "*.pem", "*.key", "*.p12", "*.p8", "*.cer", "*.mobileprovision",
    "id_rsa*", "id_ed25519*", "*.ssh/*", "*keys.plist", "*config.php*",
    "*.sqlite", "*.sqlite3", "*.db", "*.log", "users.json", "*history*.json",
    "*-zalohy/*", "*zaloha-*/*", "backup-*/*", "backup_*", "*.bak", "*.wav", "*.m4a", "*.flac", "*.mp3", "*.mov", "*.mp4",
    "Screenshot*", "*screenshot*",
]
# 3) Obsah pridaných riadkov.
SECRETS = [
    ("OpenAI kľúč",       r"sk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}"),
    ("Anthropic kľúč",    r"sk-ant-[A-Za-z0-9_-]{10,}"),
    ("Google kľúč",       r"AIza[0-9A-Za-z_-]{30,}"),
    ("GitHub token",      r"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"),
    ("Slack token",       r"xox[abposr]-[A-Za-z0-9-]{10,}"),
    ("AWS kľúč",          r"AKIA[0-9A-Z]{16}"),
    ("súkromný kľúč",     r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    ("JWT/token",         r"eyJ[A-Za-z0-9_-]{15,}\.eyJ[A-Za-z0-9_-]{15,}\."),
    ("Bearer token",      r"Bearer\s+[A-Za-z0-9._-]{24,}"),
    ("licenčný kľúč (32 hex)", r"(?<![0-9a-fA-F])[0-9a-f]{32}(?![0-9a-fA-F])"),
    ("heslo/tajomstvo v kóde", r"(?i)(password|passwd|heslo|secret|api_?key|token)\s*[:=]\s*[\"'][^\"'\s]{6,}[\"']"),
    ("n8n/webhook URL",   r"https?://[^\s\"']*/webhook(?:-test)?/[A-Za-z0-9-]{8,}"),
    ("admin URL",         r"https?://[^\s\"']*/admin/?[^\s\"']*"),
    ("SSH/server prístup", r"(?:ssh|scp|sftp)\s+(?:-\S+\s+)*[\w.-]+@[\w.-]+"),
    ("IP adresa",         r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])"),
    ("e-mail",            r"[\w.+-]+@[\w-]+\.[\w.-]+"),
]
# Známe neškodné výskyty (verejné endpointy, ktoré appka nutne volá; Sparkle verejný kľúč...).
SAFE = [
    r"noreply@anthropic\.com", r"\bCo-Authored-By\b",
    r"127\.0\.0\.1", r"0\.0\.0\.0", r"\b\d+\.\d+\.\d+\.\d+\s*\(", r"version",
    r"\[[^\]]*\]\(mailto:",
]

def mask(s): return s[:4] + "…" if len(s) > 4 else "…"

def path_problem(path):
    for pat in FORBIDDEN:
        if fnmatch.fnmatch(path, pat) or fnmatch.fnmatch(path.split("/")[-1], pat):
            return f"zakázaný súbor ({pat})"
    if not any(fnmatch.fnmatch(path, pat) for pat in ALLOWED):
        return "súbor nie je na zozname povolených (scripts/github-guard.py ALLOWED)"
    return None

def line_problems(line):
    if any(re.search(s, line) for s in SAFE):
        line = re.sub("|".join(SAFE), "", line)
    for name, pat in SECRETS:
        m = re.search(pat, line)
        if m:
            yield name, mask(m.group(0))

def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, errors="replace").stdout

def scan_commits(shas):
    """Každý commit zvlášť — tajomstvo pridané a v ďalšom commite zmazané je v histórii aj tak."""
    findings = []
    for sha in shas:
        for path in filter(None, git("show", "--format=", "--name-only", "--diff-filter=ACMR", sha).splitlines()):
            if (p := path_problem(path)):
                findings.append(f"{sha[:7]} {path}: {p}")
        cur = None
        for l in git("show", "--format=", "--unified=0", sha).splitlines():
            if l.startswith("+++ b/"): cur = l[6:]
            elif l.startswith("+") and not l.startswith("+++"):
                for name, m in line_problems(l[1:]):
                    findings.append(f"{sha[:7]} {cur}: {name} [{m}]")
        for ln in git("log", "-1", "--format=%B", sha).splitlines():
            for name, m in line_problems(ln):
                findings.append(f"{sha[:7]} správa commitu: {name} [{m}]")
    return findings

def revs(*args): return list(filter(None, git("rev-list", *args).splitlines()))

def scan_bundle(path):
    findings, blobs = [], []
    if path.endswith(".zip"):
        with zipfile.ZipFile(path) as z:
            blobs = [(n, z.read(n)) for n in z.namelist() if not n.endswith("/")]
    else:
        import os
        for root, _, files in os.walk(path):
            for f in files:
                p = os.path.join(root, f)
                with open(p, "rb") as fh: blobs.append((p, fh.read()))
    for name, data in blobs:
        if (low := name.lower()).endswith((".log", ".sqlite", ".db", ".env", ".pem", ".p12")) or "keys.plist" in low:
            findings.append(f"{name}: zakázaný súbor v balíku")
        text = data.decode("latin-1")
        for label, pat in SECRETS[:9]:   # len skutočné kľúče — binárka obsahuje kopu URL/e-mailov z frameworkov
            if label.startswith("licenčný"): continue
            for m in re.finditer(pat, text):
                findings.append(f"{name}: {label} [{mask(m.group(0))}]")
    return findings

def main():
    a = sys.argv[1:]
    if a[:1] == ["--pre-push"]:
        shas = []
        for ln in sys.stdin.read().splitlines():
            _, lsha, _, rsha = ln.split()
            if set(lsha) == {"0"}: continue                      # mazanie vetvy
            shas += revs(lsha, "--not", "--remotes") if set(rsha) == {"0"} else revs(f"{rsha}..{lsha}")
        findings = scan_commits(dict.fromkeys(shas))
    elif a[:1] == ["--range"]:   findings = scan_commits(revs(a[1]))
    elif a[:1] == ["--history"]: findings = scan_commits(revs("--all"))
    elif a[:1] == ["--bundle"]:  findings = scan_bundle(a[1])
    elif a[:1] == ["--selftest"]: return selftest()
    else: print(__doc__); return 2
    if findings:
        print("⛔ STRÁŽCA GITHUBU — push/vydanie ZASTAVENÉ, toto nesmie ísť von:")
        for f in sorted(set(findings)): print("   ", f)
        print("Oprav (vyhoď súbor/riadok, prepíš commit), alebo — ak je to naozaj neškodné —")
        print("uprav ALLOWED/SAFE v scripts/github-guard.py v samostatnom commite. Nikdy --no-verify.")
        return 1
    print("✅ Strážca GitHubu: nič citlivé nenájdené.")
    return 0

def selftest():
    # Falošné hodnoty skladané za behu, aby samotný zdroják strážcu neobsahoval nič, čo hľadá.
    x = "Ab1" * 12
    bad = ["sk-" + x, "sk-" + "proj-" + x, "sk-" + "ant-" + x, "AI" + "za" + x, "gh" + "p_" + x,
           "-----BEGIN OPENSSH " + "PRIVATE KEY-----", "Bear" + "er " + x, "ab12" * 8,
           'api_key = "' + x + '"', "https://n8n.example.sk/web" + "hook/" + "abcd1234-ef",
           "ssh " + "user" + "@server.example.sk", "10.0.0." + "12", "jan" + "@firma.sk"]
    for b in bad: assert list(line_problems(b)), b
    for ok in ["let model = \"gpt-6-luna\"", "Co-Authored-By: Claude <noreply@anthropic.com>",
               "https://paleturquoise-hedgehog-719343.hostingersite.com/api/validate.php"]:
        assert not list(line_problems(ok)), ok
    for path in ["CLAUDE.md", "ROADMAP.md", "Vyvoj/x.md", ".env", "keys.plist", "app.log",
                 "nahodny.json", "OsobnyPomocnik-zalohy/x", ".claude/settings.json"]:
        assert path_problem(path), path
    for path in ["Sources/OsobnyPomocnik/Engines/X.swift", "scripts/backup-settings.sh",
                 "README.md", "appcast.xml", "Ozvena-0.5.0.txt"]:
        assert not path_problem(path), path
    print("✅ selftest ok"); return 0

if __name__ == "__main__":
    sys.exit(main())
