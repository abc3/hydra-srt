---
name: frontend
description: Use this skill for frontend work in web_app (React/TypeScript, UI implementation, tests, and refactors).
---

# Frontend Skill

## When to use
Use for any task touching `web_app/`, React components, TypeScript, styling, or frontend tests.

## TypeScript policy
1. **All new frontend code must be TypeScript** — use `.ts` / `.tsx`, not `.js` / `.jsx`.
2. Existing JavaScript may stay as-is until you touch that file; when you edit it meaningfully, prefer migrating the changed parts to TypeScript (extract to a `.tsx` module if the file is large).
3. Put shared API/domain types in `web_app/src/types/` (e.g. `types/api.ts`).
4. Put typed API clients in `web_app/src/utils/*.ts` (see `utils/tokensApi.ts`).
5. New page/tab UI: prefer `web_app/src/pages/**/**/*.tsx`; keep legacy `.jsx` parents as thin wrappers if needed.
6. Run `npm run typecheck` before considering frontend work done; CI runs `typecheck`, `build`, and unit tests.

## Core UI rules
1. For UI elements, use only Ant Design (`antd`) components.
2. Do not build custom replacement UI controls/components when `antd` provides an equivalent.
3. Prefer composition and theming of `antd` components over custom-drawn UI.

## Workflow
1. Read existing page/component patterns before editing.
2. Keep logic separated from presentation where practical.
3. Reuse existing shared components/hooks first.
4. Add or update tests for behavior changes.
5. Run targeted tests first, then broader checks.

## Commands
- Typecheck: `cd web_app && npm run typecheck`
- Unit tests: `cd web_app && npm run test:unit`
- Watch unit tests: `cd web_app && npm run test:unit:watch`
- E2E tests: `cd web_app && npm run test:e2e`
- CI-equivalent (web): `cd web_app && npm run typecheck && npm run build && npm run test:unit:ci`

