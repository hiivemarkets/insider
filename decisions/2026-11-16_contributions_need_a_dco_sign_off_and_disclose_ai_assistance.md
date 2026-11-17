# Contributions need a DCO sign-off and disclose AI assistance

## Decision

- Every commit carries a Developer Certificate of Origin sign-off
  (`Signed-off-by:`, added by `git commit -s`) from its human author. There
  is no Contributor License Agreement. A contribution is submitted under the
  project's MIT license.
- AI-assisted contributions are allowed. The pull request names each AI tool
  that helped and says which parts it wrote or changed, in the template's
  "AI assistance" section. The person who opens the pull request is its
  author and is responsible for the whole change.
- GitHub issues are open on the public repository. Bugs, documentation
  mismatches and proposals go there. Vulnerabilities go to the private
  channel in `SECURITY.md`. Agent reports filed with
  `insider-lab live reports submit` become issues in the same repository.
- Insider has one maintainer for now, the owner in `.github/CODEOWNERS`.
  A second maintainer is recommended.

## Why

- **DCO, not a CLA.** A sign-off certifies the contributor's right to submit
  the change with one line per commit, and needs no signed agreement or
  separate system. A CLA would grant rights the MIT license does not need.
- **Disclosure, not a ban.** Insider is built for coding agents, and agents
  help build it. Disclosure lets a reviewer weigh where the change came from.
  Naming a human as responsible keeps the DCO meaningful: a tool cannot
  certify its own origin.
- **Issues.** The agent `report` flow files issues on this repository, so the
  repository must accept them once it is public.

## Consequences

- The `commit-msg` hook does not check the sign-off. Enforcement on the
  public repository, with the DCO GitHub App or an Actions check, is a
  separate change that a maintainer configures.
- Commits made before this decision carry no sign-off. They are not
  rewritten.
- An agent never signs off for a person who has not reviewed the change.
