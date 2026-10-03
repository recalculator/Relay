import Testing
@testable import RelayCore

@Suite("Command templates (pure)")
struct TemplateTests {
    @Test func placeholdersAreUniqueAndInOrderOfFirstAppearance() {
        let template = Template(parsing: "scp {{file}} {{user}}@{{host}}:/tmp/{{file}}")
        #expect(template.placeholders == ["file", "user", "host"])
        #expect(template.issues.isEmpty)
    }

    @Test func repeatedPlaceholdersReuseOneValue() {
        let template = Template(parsing: "cp {{name}}.txt {{name}}.bak")
        #expect(template.render(with: ["name": "notes"]) == "cp notes.txt notes.bak")
    }

    @Test func spacesInsideBracesAreAllowed() {
        let template = Template(parsing: "ssh {{ user }}@{{host}}")
        #expect(template.placeholders == ["user", "host"])
        #expect(template.render(with: ["user": "root", "host": "example.com"]) == "ssh root@example.com")
    }

    @Test func namesFollowTheDocumentedGrammar() {
        let valid = Template(parsing: "{{a}} {{_b}} {{c_1}} {{D2}}")
        #expect(valid.placeholders == ["a", "_b", "c_1", "D2"])
        #expect(valid.issues.isEmpty)

        for malformed in ["{{1st}}", "{{user name}}", "{{}}", "{{a-b}}", "{{ é }}", "{{x"] {
            let template = Template(parsing: malformed)
            #expect(template.placeholders.isEmpty, "\(malformed)")
            #expect(template.issues.count == 1, "\(malformed)")
        }
    }

    @Test func malformedPlaceholdersAreReportedWithTheirLineAndKeptAsLiteralText() {
        let text = "echo start\ncurl {{base url}}/x\nmkdir {{dir}}"
        let template = Template(parsing: text)
        #expect(template.placeholders == ["dir"])
        #expect(template.issues == [Template.Issue(line: 2, text: "{{base url}}")])
        #expect(template.render(with: ["dir": "out"]) == "echo start\ncurl {{base url}}/x\nmkdir out")
    }

    @Test func anOuterBraceBeforeAPlaceholderIsLiteral() {
        let template = Template(parsing: #"{"id": {{{user_id}}}}"#)
        #expect(template.placeholders == ["user_id"])
        #expect(template.issues.isEmpty)
        #expect(template.render(with: ["user_id": "42"]) == #"{"id": {42}}"#)
    }

    @Test func emptyOrMissingValuesAreReportedAndStayVisibleInThePreview() {
        let template = Template(parsing: "ssh {{user}}@{{host}}")
        #expect(template.missingValues(in: [:]) == ["user", "host"])
        #expect(template.missingValues(in: ["user": "", "host": "h"]) == ["user"])
        #expect(template.render(with: ["host": "h"]) == "ssh {{user}}@h")
        #expect(template.missingValues(in: ["user": "u", "host": "h"]).isEmpty)
    }

    @Test func substitutionIsLiteralAndNotRecursive() {
        let template = Template(parsing: "echo {{a}} {{b}}")
        let rendered = template.render(with: ["a": "{{b}}", "b": "$(rm -rf ~) \"quoted\" 'x'"])
        // The value "{{b}}" is inserted as text, not expanded; shell syntax is untouched.
        #expect(rendered == "echo {{b}} $(rm -rf ~) \"quoted\" 'x'")
    }

    @Test func unicodeAndMultilineContentSurviveUnchanged() {
        let text = """
            # Déploiement 🚀
            kubectl -n {{namespace}} \\
              rollout restart deploy/{{app}}
            echo "terminé: {{app}}"
            """
        let template = Template(parsing: text)
        #expect(template.placeholders == ["namespace", "app"])
        let rendered = template.render(with: ["namespace": "prod-ü", "app": "api✓"])
        #expect(rendered == """
            # Déploiement 🚀
            kubectl -n prod-ü \\
              rollout restart deploy/api✓
            echo "terminé: api✓"
            """)
    }

    @Test func textWithoutPlaceholdersRendersAsIs() {
        let text = "awk '{print $1}' file | sort -u"
        let template = Template(parsing: text)
        #expect(template.placeholders.isEmpty)
        #expect(template.issues.isEmpty)
        #expect(template.render(with: [:]) == text)
    }

    @Test func entryKindDecodesUnknownValuesAsSnippet() {
        #expect(EntryKind(storedValue: "template") == .template)
        #expect(EntryKind(storedValue: "snippet") == .snippet)
        #expect(EntryKind(storedValue: nil) == .snippet)
        #expect(EntryKind(storedValue: "workflow") == .snippet)
    }
}
