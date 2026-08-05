/// Everything this repository knows about the `stele` CLI, which lives in another one.
///
/// The publish skill now documents a tool this package does not build, which is a new
/// opportunity for the document to lie. The existing convention — *never retype a value
/// into the prose, interpolate it* — is what closes it, so every fact the skill states
/// about the client (where to clone it from, how to install it, the oldest build this
/// deployment accepts) is a constant here and is interpolated into `PublishSkill`.
/// `PublishSkillTests` holds the document to these, and `minimumCLIVersion` additionally to
/// the *only* version string allowed to appear anywhere in it.
///
/// Two facts and only two are hardcoded about the client repo: its clone URL and the
/// minimum version. Everything else below is derived from them or from paths the
/// client's own Makefile fixes.
public enum SteleCLI {
    /// SSH rather than HTTPS: both repositories are private, and an agent that already has
    /// a key configured clones without an interactive credential prompt it cannot answer.
    public static let repository = "git@github.com:ProJedi1234/stele-cli.git"

    /// Where the skill tells an agent to put the checkout. A fixed path, not a suggestion:
    /// every later instruction — `make -C …`, the reinstall a `426` asks for — has to name
    /// a directory, and one the document chose is one an agent can be told to reuse.
    public static let checkout = "~/repos/stele-cli"

    /// The product token the CLI identifies itself with in `User-Agent`, and the only
    /// prefix `classify(userAgent:)` reacts to.
    public static let userAgentProduct = "stele-cli"

    public static let cloneCommand = "git clone \(repository) \(checkout)"

    /// Also the remedy a `426` names, which is why it is one constant rather than a string
    /// written out once per place that suggests it.
    public static let installCommand = "make -C \(checkout) install"

    public static let completionsCommand = "make -C \(checkout) install-completions"

    /// Where the client's Makefile installs the binary (`PREFIX ?= $(HOME)/.local`). Named
    /// because a successful install followed by `command not found` reads as a failed
    /// install, and the actual fault is a `PATH` that does not include this.
    public static let binaryDirectory = "~/.local/bin"

    /// The swiftly compatibility libraries a non-interactive `swift build` cannot find on
    /// its own. The user's shell profile exports this; a shell an agent spawns does not run
    /// that profile, and the resulting failure is a linker error that names nothing useful.
    public static let compatibilityLibraries = "~/.local/share/swiftly/compat-lib"

    /// What a request's `User-Agent` says about the client that sent it.
    ///
    /// Three cases rather than an optional, because "not a stele CLI at all" and "a stele
    /// CLI whose version is gibberish" call for opposite answers: the first is curl or a
    /// browser and must be waved through, the second is a broken or hand-forged client and
    /// is told to reinstall.
    public static func classify(userAgent raw: String?) -> CLIUserAgent {
        guard let raw else { return .notTheCLI }
        // A `User-Agent` is a list of products with optional comments, so the token is
        // looked for anywhere in it rather than only at the front — a wrapper that prepends
        // its own product is still a CLI request.
        let marker = "\(userAgentProduct)/"
        for token in raw.split(whereSeparator: \.isWhitespace) where token.hasPrefix(marker) {
            let presented = token.dropFirst(marker.count)
            guard let version = CLIVersion(parsing: presented) else {
                return .unreadableVersion(String(presented))
            }
            return .version(version)
        }
        return .notTheCLI
    }
}

public enum CLIUserAgent: Sendable, Equatable {
    /// No `stele-cli/…` product token. Curl, a browser, a script — not gated.
    case notTheCLI
    case version(CLIVersion)
    case unreadableVersion(String)
}

/// The oldest `stele` CLI build this deployment accepts writes from.
///
/// A constant in the server rather than a value the client asserts about itself, because
/// the question it answers is "does this deployment still speak that client's dialect?" and
/// only the deployment can answer it. Raising it is a deliberate act that breaks every
/// installed client older than the new value, so raise it when the wire contract actually
/// moves — not when the CLI merely gains a feature.
///
/// A top-level constant, like `buildRouter` and `notFoundPage`, so every use site reads as
/// the sentence it is: `presented >= minimumCLIVersion`.
public let minimumCLIVersion = CLIVersion(0, 1, 0)

/// A `major.minor.patch` version of the CLI.
///
/// Ordered rather than compared for equality: the gate asks "at least", so a client from
/// the future is fine and only a client from the past is not.
public struct CLIVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `1.2.3`, and treats `1.2.3-dev` or `1.2.3+abc123` as `1.2.3`.
    ///
    /// Prerelease and build metadata are discarded rather than ordered below the release,
    /// which is a deliberate departure from SemVer §11: the only thing that carries a
    /// `-dev` suffix here is a build made from the client's working tree, and answering a
    /// developer's own build with "upgrade required" would be a confusing lie about a
    /// binary that is by definition newer than the release it is named after.
    ///
    /// Strict about the rest. `Int` accepts a leading `+`/`-` and Unicode digits, so the
    /// components are checked for ASCII digits before conversion — otherwise `1.+2.3` would
    /// parse and a nonsense version would authenticate as a modern one.
    public init?(parsing raw: some StringProtocol) {
        let core = raw.prefix { $0 != "-" && $0 != "+" }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else { return nil }
        guard let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
        else { return nil }
        self.init(major, minor, patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
