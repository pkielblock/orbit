import AppKit
import SwiftUI
import XCTest
@testable import Orbit

/// Hosts the real sheet in a window that is never shown.
@MainActor
final class ProviderAccountsViewTests: XCTestCase {
    private func account(_ name: String) -> Account {
        Account(id: UUID(), provider: .claude, name: name, folder: "/Users/example/.claude-\(name)")
    }

    private func model(_ accounts: [Account]) -> GalaxyModel {
        let model = GalaxyModel()
        model.accounts = accounts // assigned directly, so nothing is saved
        return model
    }

    private func host(_ model: GalaxyModel) -> (NSWindow, NSView) {
        let view = NSHostingView(rootView: ProviderAccounts(model: model, provider: .claude, refresh: {}))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        settle(view)
        return (window, view)
    }

    private func settle(_ view: NSView) {
        for _ in 0..<5 {
            view.setFrameSize(view.fittingSize)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private func fields(in view: NSView) -> [NSTextField] {
        ((view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []) + view.subviews.flatMap(fields)
    }

    func testHeightHugsContentUpToTheLimit() {
        let (_, short) = host(model([Account.defaultAccount(.claude)]))
        XCTAssertLessThan(short.fittingSize.height, 400)
        XCTAssertGreaterThan(short.fittingSize.height, 200)
        let (_, long) = host(model([Account.defaultAccount(.claude)] + (0..<12).map { account("a\($0)") }))
        XCTAssertEqual(long.fittingSize.height, 560)
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        (view as? NSScrollView) ?? view.subviews.lazy.compactMap(scrollView).first
    }

    func testOpeningTheFormInAFullSheetScrollsToIt() throws {
        let model = model([Account.defaultAccount(.claude)] + (0..<6).map { account("a\($0)") })
        let (window, view) = host(model)
        _ = window
        let scroller = try XCTUnwrap(scrollView(in: view))
        XCTAssertEqual(scroller.documentVisibleRect.minY, 0)
        let closedHeight = try XCTUnwrap(scroller.documentView).bounds.height
        model.addingAccount = true
        settle(view)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4)) // the scroll animation
        let document = try XCTUnwrap(scroller.documentView).bounds
        XCTAssertGreaterThan(document.height, closedHeight, "the form opened")
        // The form sits above the help link at the document's end.
        XCTAssertEqual(scroller.documentVisibleRect.maxY, document.maxY, accuracy: 60, "the form is in view")
    }

    /// Typing near the limit while a result moves the sheet over it must not save half a name or lose the field.
    func testTypingSurvivesCrossingTheHeightLimit() throws {
        let work = account("work")
        let model = model([Account.defaultAccount(.claude), work, account("other")])
        for other in model.accounts { model.usage[other.id] = ProviderUsage(provider: .claude) } // connected: no command lines
        let (window, view) = host(model)
        XCTAssertLessThan(view.fittingSize.height, 560)
        let field = try XCTUnwrap(fields(in: view).first { $0.stringValue == "work" })
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Wo", replacementRange: editor.selectedRange())
        settle(view)

        for other in model.accounts { model.usage[other.id] = ProviderUsage(provider: .claude, needsConnection: true) }
        settle(view)
        XCTAssertEqual(view.fittingSize.height, 560, "the fixture has to cross the limit")

        XCTAssertEqual(model.accounts.first { $0.id == work.id }?.name, "work", "half a name is not saved")
        XCTAssertTrue(fields(in: view).contains { $0 === field }, "the same field stays")
        XCTAssertEqual(field.currentEditor()?.string, "Wo")
    }

    func testRenameIsNotUndoneWhenTheNameChangesFromOutsideTheField() {
        let work = account("work")
        let model = model([Account.defaultAccount(.claude), work])
        let (_, view) = host(model)
        // A row with nothing typed follows the stored name and never writes its old draft back.
        model.accounts[1].name = "New"
        settle(view)
        XCTAssertTrue(fields(in: view).contains { $0.stringValue == "New" })
        XCTAssertEqual(model.accounts[1].name, "New")
    }
}
