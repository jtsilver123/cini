# AGENTS.md

This repository's full agent instructions live in **[`CLAUDE.md`](./CLAUDE.md)**
(operating manual: golden rules, repo map, workflow, build policy, backend,
gotchas). Read it first, whatever tool you are.

Companion docs:
- **`docs/DESIGN.md`** — design system (brand, tokens, components, UI laws).
- **`docs/ARCHITECTURE.md`** — ranking engine, persistence, RLS, taste match.
- **`docs/HANDOFF.md`** — running status log + build/credentials history.

The five rules you most often trip on (full list in `CLAUDE.md` §2):
1. **Never trigger a TestFlight build unless the user explicitly asks.**
2. **Movies and TV are the only content types** — equal everywhere.
3. **Reuse shared components/`Theme` tokens** — identical actions in identical places.
4. **Mirror user-visible changes in `prototype/index.html`.**
5. **The repo is public** — no secrets in commits; keep model/harness identity
   out of all pushed artifacts.

After any backend/query change, run `python3 scripts/contract_check.py`
("All contracts hold.") and gate every push on a green `ci.yml` run.
