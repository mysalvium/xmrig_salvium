## Summary

Describe the owning branch, the intended target, and the complete scope.

## Mandatory repository safety

- [ ] I verified the exact base repository and base branch.
- [ ] I verified the exact head repository and head branch.
- [ ] This PR does not send the personal donation layer to `xmrig/xmrig`.
- [ ] If the base is `xmrig/xmrig`, the head is a clean topic branch based
      directly on `upstream/master`, not `donation`, `combined`, or a
      descendant of either.
- [ ] If the base is `xmrig/xmrig`, I ran
      `git check-upstream-pr xmrig/xmrig HEAD upstream/master`,
      reviewed the complete diff, and received explicit user confirmation
      naming `xmrig/xmrig`.

Do not create, update, or retarget the PR if any safety item is false or
uncertain.
