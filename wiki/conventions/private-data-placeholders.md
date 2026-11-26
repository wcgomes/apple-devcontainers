# Convention: Private data placeholders

Never put the maintainer's private work-project names, container or volume names, or personal name/email into code, tests, fixtures, specs, docs, or the wiki.

- Use generic placeholders: `sample-app`, `my-app`, `user@example.com`.
- Describe incidents generically (symptom, mechanism, fix), without the real project, container, or volume names.
- The GitHub handle in repo, registry, and Homebrew tap URLs is public identity and stays.
- Check before committing: `git grep -inE "<private-term>"` over the changed paths returns nothing.
