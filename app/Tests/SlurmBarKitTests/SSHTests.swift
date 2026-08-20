import XCTest
@testable import SlurmBarKit

final class ShellQuotingTests: XCTestCase {
    func testSafeValuesAreNotQuoted() {
        XCTAssertEqual(ShellQuoting.quote("snapshot"), "snapshot")
        XCTAssertEqual(ShellQuoting.quote("--job-id"), "--job-id")
        XCTAssertEqual(ShellQuoting.quote("/usr/bin/python3"), "/usr/bin/python3")
        XCTAssertEqual(ShellQuoting.quote("201560_7"), "201560_7")
    }

    func testEmptyStringBecomesAnExplicitEmptyWord() {
        XCTAssertEqual(ShellQuoting.quote(""), "''")
    }

    func testSpacesAreQuoted() {
        XCTAssertEqual(ShellQuoting.quote("two words"), "'two words'")
    }

    func testShellMetacharactersAreNeutralized() {
        // These would be catastrophic unquoted: the remote login shell interprets the string.
        for dangerous in [
            "a; rm -rf ~",
            "a && scancel 999",
            "a | tee /tmp/x",
            "$(whoami)",
            "`id`",
            "a > /etc/passwd",
            "*",
            "~/../../etc",
            "a\nb",
        ] {
            let quoted = ShellQuoting.quote(dangerous)
            XCTAssertTrue(quoted.hasPrefix("'"), "\(dangerous) was not quoted")
            XCTAssertTrue(quoted.hasSuffix("'"), "\(dangerous) was not quoted")
        }
    }

    func testEmbeddedSingleQuoteIsEscapedCorrectly() {
        // The only character that cannot live inside single quotes.
        XCTAssertEqual(ShellQuoting.quote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(ShellQuoting.quote("'"), #"''\'''"#)
    }

    func testJoinQuotesEveryArgumentButLeavesTheTildeExpandable() {
        // The tilde must stay outside the quotes or the remote shell sends a literal "~".
        // (Previously asserted "'~/my agent.pyz'", which is what broke against a real cluster.)
        let joined = ShellQuoting.join(["python3", "~/my agent.pyz", "snapshot", "--json"])
        XCTAssertEqual(joined, "python3 ~/'my agent.pyz' snapshot --json")
    }

    func testTildeStaysOutsideQuotesSoTheRemoteShellExpandsIt() {
        // Quoting the tilde would send a literal "~" that never resolves to $HOME.
        XCTAssertEqual(ShellQuoting.quoteRemotePath("~"), "~")
        XCTAssertEqual(
            ShellQuoting.quoteRemotePath("~/.local/share/slurmbar/slurmbar-agent.pyz"),
            "~/.local/share/slurmbar/slurmbar-agent.pyz"
        )
        XCTAssertEqual(ShellQuoting.quoteRemotePath("~/my dir/agent.pyz"), "~/'my dir/agent.pyz'")
    }

    func testAbsolutePathsAreQuotedNormally() {
        XCTAssertEqual(ShellQuoting.quoteRemotePath("/opt/a b/agent.pyz"), "'/opt/a b/agent.pyz'")
    }
}

final class SSHArgumentTests: XCTestCase {
    func testAlwaysUsesBatchModeAndNeverDisablesHostKeyChecking() {
        let runner = SSHCommandRunner(alias: "example-cluster", connectTimeout: 8)
        let arguments = runner.sshArguments(remoteCommand: "python3 agent.pyz snapshot --json")

        XCTAssertTrue(arguments.contains("BatchMode=yes"), "BatchMode is what prevents password prompts")
        XCTAssertTrue(arguments.contains("ConnectTimeout=8"))
        XCTAssertTrue(arguments.contains("-T"))
        XCTAssertEqual(arguments.last, "python3 agent.pyz snapshot --json")

        let joined = arguments.joined(separator: " ")
        XCTAssertFalse(joined.contains("StrictHostKeyChecking"))
        XCTAssertFalse(joined.contains("UserKnownHostsFile"))
        XCTAssertFalse(joined.contains("PasswordAuthentication=yes"))
    }

    func testAliasIsAPositionalArgumentNotInterpolated() {
        let runner = SSHCommandRunner(alias: "example-cluster")
        let arguments = runner.sshArguments(remoteCommand: "echo hi")
        let aliasIndex = try? XCTUnwrap(arguments.firstIndex(of: "example-cluster"))
        XCTAssertNotNil(aliasIndex)
    }

    func testUsernameOverrideUsesTheDashLFlag() {
        let runner = SSHCommandRunner(alias: "example-cluster", username: "otheruser")
        let arguments = runner.sshArguments(remoteCommand: "echo hi")
        let index = arguments.firstIndex(of: "-l")
        XCTAssertNotNil(index)
        XCTAssertEqual(arguments[(index ?? 0) + 1], "otheruser")
    }

    func testNoUsernameFlagWhenNotOverridden() {
        let runner = SSHCommandRunner(alias: "example-cluster")
        XCTAssertFalse(runner.sshArguments(remoteCommand: "echo hi").contains("-l"))
    }

    func testDisplayCommandIsCopyPasteable() {
        let runner = SSHCommandRunner(alias: "example-cluster")
        let display = runner.displayCommand(remoteCommand: "python3 agent.pyz snapshot --json")
        XCTAssertTrue(display.hasPrefix("/usr/bin/ssh"))
        XCTAssertTrue(display.contains("BatchMode=yes"))
    }
}

final class InteractiveSSHLoginTests: XCTestCase {
    func testUsesInteractiveMasterModeForTheSelectedProfile() throws {
        let profile = ClusterProfile(
            displayName: "NCHC",
            sshAlias: "NCHC-SlurmBar",
            username: "example-user"
        )

        XCTAssertEqual(
            try InteractiveSSHLogin.command(profile: profile),
            "/usr/bin/ssh -o BatchMode=no -M -N -f -l example-user NCHC-SlurmBar"
        )
    }

    func testTerminalScriptNeverDisablesHostKeyCheckingOrContainsCredentials() throws {
        let profile = ClusterProfile(displayName: "Cluster", sshAlias: "cluster.example")
        let script = try InteractiveSSHLogin.terminalScript(profile: profile)

        XCTAssertTrue(script.contains("BatchMode=no"))
        XCTAssertTrue(script.contains("never receives or stores"))
        XCTAssertFalse(script.contains("StrictHostKeyChecking"))
        XCTAssertFalse(script.contains("UserKnownHostsFile"))
        XCTAssertFalse(script.lowercased().contains("password="))
    }

    func testShellMetacharactersInAliasRemainQuotedData() throws {
        let profile = ClusterProfile(displayName: "Cluster", sshAlias: "cluster;touch-owned")
        let command = try InteractiveSSHLogin.command(profile: profile)

        XCTAssertTrue(command.hasSuffix("'cluster;touch-owned'"), "got: \(command)")
        XCTAssertFalse(command.hasSuffix(" cluster;touch-owned"))
    }

    func testInvalidProfileCannotCreateInteractiveCommand() {
        let profile = ClusterProfile(displayName: "Cluster", sshAlias: "-ProxyCommand=bad")
        XCTAssertThrowsError(try InteractiveSSHLogin.command(profile: profile))
    }
}

final class SSHErrorClassificationTests: XCTestCase {
    private func classify(_ stderr: String, exitCode: Int32 = 255) -> SSHFailure {
        SSHErrorClassifier.classify(exitCode: exitCode, stderr: stderr, alias: "example-cluster", timeout: 12)
    }

    // Each of these strings is real OpenSSH wording.

    func testUnknownHostAlias() {
        let failure = classify("ssh: Could not resolve hostname example-cluster: nodename nor servname provided, or not known")
        guard case .aliasNotFound(let alias) = failure else { return XCTFail("got \(failure)") }
        XCTAssertEqual(alias, "example-cluster")
        XCTAssertTrue(failure.recoverySuggestion?.contains("~/.ssh/config") ?? false)
    }

    func testVPNDownLooksLikeATimeout() {
        let failure = classify("ssh: connect to host login.example.org port 22: Operation timed out")
        guard case .hostUnreachable = failure else { return XCTFail("got \(failure)") }
        XCTAssertTrue(failure.isTransient)
        XCTAssertTrue(failure.recoverySuggestion?.contains("VPN") ?? false)
    }

    func testNetworkUnreachable() {
        let failure = classify("ssh: connect to host login.example.org port 22: Network is unreachable")
        guard case .networkUnreachable = failure else { return XCTFail("got \(failure)") }
        XCTAssertTrue(failure.isTransient)
    }

    func testConnectionRefused() {
        let failure = classify("ssh: connect to host login.example.org port 22: Connection refused")
        guard case .connectionRefused = failure else { return XCTFail("got \(failure)") }
    }

    func testPublicKeyRejection() {
        let failure = classify("exampleuser@login.example.org: Permission denied (publickey,gssapi-keyex).")
        guard case .authenticationFailed = failure else { return XCTFail("got \(failure)") }
        // The suggestion must never imply SlurmBar can ask for a password.
        XCTAssertTrue(failure.recoverySuggestion?.contains("ssh-add") ?? false)
        XCTAssertFalse(failure.isTransient)
    }

    func testHostKeyVerificationFailure() {
        let failure = classify("Host key verification failed.")
        guard case .hostKeyUnknown = failure else { return XCTFail("got \(failure)") }
        XCTAssertTrue(failure.recoverySuggestion?.contains("verify the fingerprint") ?? false)
    }

    func testChangedHostKeyIsDistinctFromAnUnknownOne() {
        let stderr = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
        """
        let failure = classify(stderr)
        guard case .hostKeyMismatch = failure else { return XCTFail("got \(failure)") }
        XCTAssertTrue(failure.recoverySuggestion?.contains("man-in-the-middle") ?? false)
        XCTAssertFalse(failure.isTransient, "a changed host key must never be silently retried")
    }

    func testMissingRemoteAgent() {
        let failure = classify(
            "python3: can't open file '/home/exampleuser/.local/share/slurmbar/slurmbar-agent.pyz': [Errno 2] No such file or directory",
            exitCode: 2
        )
        guard case .remoteAgentMissing = failure else { return XCTFail("got \(failure)") }
        XCTAssertTrue(failure.recoverySuggestion?.contains("Install or Update Agent") ?? false)
    }

    func testMissingRemotePython() {
        let failure = classify("bash: python3: command not found", exitCode: 127)
        guard case .remotePythonMissing = failure else { return XCTFail("got \(failure)") }
    }

    func testUnrecognizedNonZeroExitKeepsTheStderr() {
        let failure = classify("slurmbar-agent: something unusual happened", exitCode: 3)
        guard case .remoteCommandFailed(let code, let stderr) = failure else { return XCTFail("got \(failure)") }
        XCTAssertEqual(code, 3)
        XCTAssertTrue(stderr.contains("something unusual"))
    }

    func testExit255WithoutRecognizableTextIsStillAnSSHProblem() {
        let failure = classify("", exitCode: 255)
        guard case .hostUnreachable = failure else { return XCTFail("got \(failure)") }
    }

    func testBannerNoiseIsSkippedWhenPickingTheMessage() {
        let stderr = """
        Warning: Permanently added 'login.example.org' (ED25519) to the list of known hosts.
        slurmbar-agent: real problem here
        """
        let line = SSHErrorClassifier.firstMeaningfulLine(stderr)
        XCTAssertEqual(line, "slurmbar-agent: real problem here")
    }

    func testEveryFailureHasATitleAndMessage() {
        let failures: [SSHFailure] = [
            .aliasNotFound(alias: "a"), .hostUnreachable(detail: ""), .connectionRefused(detail: ""),
            .networkUnreachable(detail: ""), .authenticationFailed(detail: ""), .hostKeyUnknown(detail: ""),
            .hostKeyMismatch(detail: ""), .permissionDenied(detail: "d"), .timedOut(seconds: 12),
            .cancelled, .remoteAgentMissing(detail: ""), .remotePythonMissing(detail: ""),
            .remoteCommandFailed(exitCode: 1, stderr: ""), .sshUnavailable(path: "/usr/bin/ssh"),
            .launchFailed(detail: "d"), .protocolFailure(.emptyResponse),
        ]
        for failure in failures {
            XCTAssertFalse(failure.title.isEmpty, "\(failure) has no title")
            XCTAssertFalse(failure.message.isEmpty, "\(failure) has no message")
            XCTAssertFalse(failure.symbolName.isEmpty, "\(failure) has no symbol")
            // The whole point of the type: nothing collapses into "Unknown error".
            XCTAssertFalse(failure.title.lowercased().contains("unknown error"))
        }
    }
}

final class JobIDValidationTests: XCTestCase {
    func testAcceptsPlainAndArrayIDs() throws {
        XCTAssertEqual(try JobIDValidator.validate("201551"), "201551")
        XCTAssertEqual(try JobIDValidator.validate("201560_7"), "201560_7")
        XCTAssertEqual(try JobIDValidator.validate("  201551  "), "201551")
    }

    func testRejectsInjectionAttempts() {
        for bad in [
            "", "  ", "abc", "201551; rm -rf ~", "201551 && scancel 999", "$(id)", "`whoami`",
            "../../etc/passwd", "201551|cat", "201551 201552", "-1", "201551_", "_7",
            "201551_[1-5]", "201551.batch", String(repeating: "9", count: 50),
        ] {
            XCTAssertThrowsError(try JobIDValidator.validate(bad), "\(bad) should be rejected")
            XCTAssertFalse(JobIDValidator.isValid(bad), "\(bad) should be invalid")
        }
    }
}

final class CommandLineTokenizerTests: XCTestCase {
    func testSimpleSplit() {
        XCTAssertEqual(
            CommandLineTokenizer.tokenize("python3 ~/.local/share/slurmbar/slurmbar-agent.pyz"),
            ["python3", "~/.local/share/slurmbar/slurmbar-agent.pyz"]
        )
    }

    func testQuotedSegmentsStayTogether() {
        XCTAssertEqual(
            CommandLineTokenizer.tokenize(#"python3 "/opt/my agent/agent.pyz""#),
            ["python3", "/opt/my agent/agent.pyz"]
        )
        XCTAssertEqual(CommandLineTokenizer.tokenize("a 'b c' d"), ["a", "b c", "d"])
    }

    func testBackslashEscapes() {
        XCTAssertEqual(CommandLineTokenizer.tokenize(#"a b\ c"#), ["a", "b c"])
    }

    func testEmptyInput() {
        XCTAssertEqual(CommandLineTokenizer.tokenize("   "), [])
        XCTAssertEqual(ClusterProfile.parseAgentCommand("  "), ClusterProfile.defaultAgentCommand)
    }

    func testRoundTripsThroughTheProfileDisplayString() {
        var profile = ClusterProfile()
        profile.agentCommand = ["python3", "/opt/my agent/agent.pyz"]
        let round = ClusterProfile.parseAgentCommand(profile.agentCommandString)
        XCTAssertEqual(round, profile.agentCommand)
    }
}

final class SanitizedTextTests: XCTestCase {
    func testStripsANSIEscapes() {
        XCTAssertEqual(SanitizedText.clean("\u{1B}[31mred\u{1B}[0m"), "red")
    }

    func testStripsControlCharactersButKeepsTabs() {
        XCTAssertEqual(SanitizedText.clean("a\u{0}b\u{07}c\td"), "abc\td")
    }

    func testStripsBidiOverrides() {
        // These can visually reverse text, e.g. to disguise a job name.
        XCTAssertEqual(SanitizedText.clean("safe\u{202E}gnp.exe"), "safegnp.exe")
    }

    func testTruncatesLongInput() {
        let long = String(repeating: "x", count: 5000)
        let cleaned = SanitizedText.clean(long, limit: 100)
        XCTAssertEqual(cleaned.count, 101)  // 100 + ellipsis
        XCTAssertTrue(cleaned.hasSuffix("…"))
    }

    func testLeavesOrdinaryTextAlone() {
        XCTAssertEqual(SanitizedText.clean("example-training"), "example-training")
    }
}

/// Regression tests for remote-shell quoting defects.
final class RemoteShellQuotingTests: XCTestCase {
    func testAgentCommandTildeSurvivesJoining() {
        // A quoted tilde makes the remote Python report
        //   can't open file '/home/user/~/.local/share/slurmbar/slurmbar-agent.pyz'
        // because join() single-quoted the tilde, so the login shell never expanded it.
        let joined = ShellQuoting.join([
            "python3", "~/.local/share/slurmbar/slurmbar-agent.pyz", "snapshot", "--json",
        ])
        XCTAssertEqual(joined, "python3 ~/.local/share/slurmbar/slurmbar-agent.pyz snapshot --json")
        XCTAssertFalse(joined.contains("'~"), "the tilde must not be quoted")
    }

    func testJoinStillQuotesDangerousArguments() {
        let joined = ShellQuoting.join(["python3", "~/a b/agent.pyz", "logs", "--path", "/x; rm -rf ~"])
        XCTAssertTrue(joined.contains("~/'a b/agent.pyz'"))
        XCTAssertTrue(joined.contains("'/x; rm -rf ~'"))
    }

    func testFullSSHInvocationKeepsTheTildeUnquoted() {
        let runner = SSHCommandRunner(alias: "example-cluster")
        let remote = ShellQuoting.join(["python3", "~/.local/share/slurmbar/slurmbar-agent.pyz", "doctor"])
        let argv = runner.sshArguments(remoteCommand: remote)
        let command = try? XCTUnwrap(argv.last)
        XCTAssertEqual(command, "python3 ~/.local/share/slurmbar/slurmbar-agent.pyz doctor")
    }

    func testAgentClientProducesATildeSafeCommandLine() async throws {
        // End-to-end through AgentClient: the argv it hands the runner must join cleanly.
        let runner = StubRemoteRunner(json: #"{"schema_version":1,"generated_at":"2026-07-22T02:30:00Z","ok":true,"checks":[],"warnings":[]}"#)
        let profile = ClusterProfile(displayName: "X", sshAlias: "example-cluster")
        _ = try await AgentClient(runner: runner, profile: profile).doctor()

        let argv = try XCTUnwrap(runner.invocations.first)
        let joined = ShellQuoting.join(argv)
        XCTAssertTrue(
            joined.hasPrefix("python3 ~/.local/share/slurmbar/slurmbar-agent.pyz"),
            "got: \(joined)"
        )
    }
}

/// A cluster requiring an OTP can reject a fresh BatchMode connection with
/// `Permission denied (keyboard-interactive)`. SlurmBar can only work there while a
/// ControlMaster connection is alive, and the error has to say so.
final class InteractiveAuthTests: XCTestCase {
    private func classify(_ stderr: String) -> SSHFailure {
        SSHErrorClassifier.classify(exitCode: 255, stderr: stderr, alias: "my-cluster", timeout: 12)
    }

    func testKeyboardInteractiveIsItsOwnFailure() {
        let failure = classify("exampleuser@login.example.org: Permission denied (keyboard-interactive).")
        guard case .interactiveAuthRequired = failure else { return XCTFail("got \(failure)") }
        XCTAssertEqual(failure.title, "Interactive login required")
    }

    func testAdviceMentionsTerminalAndControlMasterNotSSHAdd() {
        let failure = classify("Permission denied (keyboard-interactive).")
        let advice = try? XCTUnwrap(failure.recoverySuggestion)
        XCTAssertTrue(advice?.contains("ControlMaster") ?? false)
        XCTAssertTrue(advice?.contains("Terminal") ?? false)
        // Telling the user to run ssh-add here would be a dead end.
        XCTAssertFalse(advice?.contains("ssh-add") ?? true)
    }

    func testPasswordPromptRejectionIsAlsoInteractive() {
        guard case .interactiveAuthRequired = classify("Permission denied (password).") else {
            return XCTFail("password rejection should be interactive")
        }
    }

    func testPlainPublickeyRejectionIsStillAKeyProblem() {
        // A pure publickey rejection is a different fix and must not be reclassified.
        guard case .authenticationFailed = classify("Permission denied (publickey).") else {
            return XCTFail("publickey rejection should stay authenticationFailed")
        }
    }

    func testNotTransientSoThePollLoopBacksOff() {
        XCTAssertFalse(classify("Permission denied (keyboard-interactive).").isTransient)
    }
}
