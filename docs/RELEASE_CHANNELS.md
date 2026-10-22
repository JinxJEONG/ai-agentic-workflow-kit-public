# Release channels

The canary names in `release-channels.json` are synthetic examples. Configure
real adoption targets in a private operational copy before evaluating promotion.
Do not publish internal project inventories in the shared kit.

Projects always pin an exact `kit_bundle_digest`; they never follow a channel.
The `candidate` and `stable` channels only express an organizational
recommendation.

A candidate may become stable only after all synthetic fixtures pass, both
canary repositories pass their required gate, the candidate has aged for the
configured minimum, and a human explicitly approves promotion. Promotion does
not edit any project lock.

`null` digest values mean no verified local release exists yet. They are not a
wildcard and must never be accepted by a resolver.
