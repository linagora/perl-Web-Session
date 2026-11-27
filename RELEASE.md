# Release process

## Version

Set the new version in:

- `dist_version` in `Build.PL`
- `$VERSION` of every module in `lib/`
- `real_version` in `rpm/perl-Web-Session.spec`

Check them with:

```
perl .github/check-version.pl vX.Y.Z
```

## Changes

Update changelog in `Changes` file: its first entry must be the new version.

## Tag and CPAN upload

Tag the release commit and push the tag:

```
git tag vX.Y.Z
git push origin vX.Y.Z
```

The `Release` workflow then checks that the tag matches the versions above
and the first entry of `Changes`, builds and tests the distribution, and
uploads `Web-Session-X.Y.Z.tar.gz` to CPAN. It needs the `PAUSE_USERNAME` and
`PAUSE_PASSWORD` secrets of the repository. If the check fails, nothing is
uploaded: delete the tag, fix the versions and tag again.

## Github release

Create a new release on [https://github.com/linagora/perl-Web-Session/releases](https://github.com/linagora/perl-Web-Session/releases)
