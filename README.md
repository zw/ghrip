Poll GitHub for issue/pull request data associated with a repository and commit
that data to its own repository, for the purposes of backup, archival or
export.

You should look at [github-backup][] first.  The use case for this tool is
similar &mdash; having a fallback (even if ugly) during GitHub outages or if
GitHub decides to take down your repository &mdash; but this is much less
featureful and mature.  Without having actually tried github-backup, the
motivation for writing new code was:

 * github-backup doesn't (yet) archive labels and milestones and it's not
   clear that it includes pull request review comments; review comments are
   especially important to to the target environment for this tool
 * github-backup archives the repository (and all branches), whereas this tool
   assumes you have complete local copies of repos already
 * github-backup uses its own serialisation format (something built into
   Haskell) whereas I'm too paranoid to trust as complete any data that's done
   a trip through a strict type system
 * github-backup "re-downloads all issues, comments, and so on each time it's
   run" &mdash; backup has to be easy and quick or it won't happen
 * most importantly, the above could be fixed but github-backup is in Haskell,
   and the target environment for this tool is not a Haskell shop

 [github-backup]: https://github.com/joeyh/github-backup

Commits are not yet implemented and there's no documentation yet outside the
source.  There are zero formal tests and the code has seen little real world
exercise at this point.  While a decent effort is made to be efficient and
incremental, there's currently no attempt to adhere to API rate limits (since
moving from Net::Github to Pithub) which will probably bite you on the first
run on any larger repo.

Takes no options or arguments but see source for environment variables.
Populates an `issues/` subdirectory in the CWD with various data (`*.json`).
Also leaves `state.json` in the CWD for incremental updates, not intended to be
checked in.

Licence: [Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0)
