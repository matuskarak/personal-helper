#!/bin/bash
# Nainštaluje git pre-push hook so strážcom GitHubu (scripts/github-guard.py).
# .git/hooks sa neverzuje — po novom klone spusti raz; release.sh to robí sám.
set -e
cd "$(git rev-parse --show-toplevel)"
cat > .git/hooks/pre-push <<'HOOK'
#!/bin/bash
# Strážca GitHubu — repo je verejné. Neobchádzať (--no-verify je zakázané).
exec python3 "$(git rev-parse --show-toplevel)/scripts/github-guard.py" --pre-push
HOOK
chmod +x .git/hooks/pre-push
echo "✅ pre-push strážca nainštalovaný"
