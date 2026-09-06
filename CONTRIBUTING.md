# How to contribute to the Exercism Sather Test Runner

## Contributing

We 💙 our community, but **this repository does not accept unsolicited pull requests at this time**.

Please read this [community blog post][guidelines] for details.

### How to contribute

1. Open a topic on the [Sather forum][sather-forum]
2. Discuss the proposal with the maintainers
3. After receiving the go-ahead, submit a pull request

Pull requests are automatically closed and will **remain closed until approved by a maintainer**.

Pull requests must follow [Exercism's style guide][style].

Before submitting, please read:

- [Contributors Pull Request Guide][contributors-pr-guide]
- [Pull Request Guide][pr-guide]

When opening a PR:

- Clearly describe the problem and the solution
- Link to the corresponding forum discussion
- Add a link to the PR in that same discussion

### Compiler

The Sather compiler in the image is built from the GNU 1.2.2
tarball plus the patches in [`patches/`](patches/).

Each patch should:

- be as small as the fix allows;
- explain what breaks without it and why the fix is shaped the way it is;

[guidelines]: https://exercism.org/blog/contribution-guidelines-nov-2023
[sather-forum]: https://forum.exercism.org/c/programming/sather
[style]: https://exercism.org/docs/building/markdown/style-guide
[contributors-pr-guide]: https://exercism.org/docs/building/github/contributors-pull-request-guide
[pr-guide]: https://exercism.org/docs/community/being-a-good-community-member/pull-requests
