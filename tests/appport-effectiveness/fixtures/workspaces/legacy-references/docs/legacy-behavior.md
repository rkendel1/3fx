# Established behavior of extractTaskRefs

Downstream tools depend on all of the following. Preserve each one exactly.

- References are returned as numbers, in the order they first appear.
- A repeated reference is returned once, at its first position.
- Leading zeros are ignored: `vikunja-task:007` is task 7.
- A reference written as `~vikunja-task:<id>` is cancelled and is not returned.
- `vikunja-task:0` is not a task and is not returned.
- A marker without digits is ignored.
