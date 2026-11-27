# Release process

## One-time setup

- Create a `cpan` environment in the repository settings (Settings >
  Environments), with required reviewers, and add its `PAUSE_USERNAME` and
  `PAUSE_PASSWORD` secrets. The CPAN upload waits for a reviewer's approval.
- The PAUSE account must have permissions on the `Web::Session` namespace.

## Version

Set the new version in:

- `dist_version` in `Build.PL`
- `$VERSION` of every module in `lib/`
- `real_version` in `rpm/perl-Web-Session.spec`

Check them with (the CI runs it too):

```
perl .github/check-version.pl vX.Y.Z
```

## Changes

Update changelog in `Changes` file: its first entry must be the new version.
This entry is also the text of the GitHub release.

## Tag

Once the release commit is on `master` and its CI passed, tag it and push the
tag:

```
git tag vX.Y.Z
git push origin vX.Y.Z
```

The `Release` workflow then:

1. checks that the tag matches the versions above and the first entry of
   `Changes`, and that the tagged commit is on `master`;
2. builds and tests the distribution `Web-Session-X.Y.Z.tar.gz`;
3. builds the Debian package `libweb-session-perl_X.Y.Z-1_all.deb` (Debian
   trixie, with `dh-make-perl`);
4. creates the GitHub release vX.Y.Z with both files as assets;
5. uploads the distribution to CPAN, after approval in the `cpan`
   environment.

If a check fails before the release is created, nothing is published: delete
the tag, fix and tag again:

```
git tag -d vX.Y.Z
git push origin :vX.Y.Z
```

Once the release exists, delete it on GitHub before tagging again. A CPAN
upload can't be redone: PAUSE refuses a file name already uploaded, so
re-running the workflow after a successful upload fails at the last step;
publish a new version instead.
