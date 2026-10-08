import AppKit
import Testing
@testable import RivetSystem

@MainActor
@Test func menuBarMenuContainsSeparatorsAndActions() {
    let controller = RivetMenuBarController()
    var fired = false
    controller.install(
        title: "Test",
        items: [
            .action(label: "Show", identifier: "show", handler: {}),
            .separator,
            .action(label: "Quit", identifier: "quit", handler: { fired = true }),
        ])
    defer { controller.remove() }

    let menu = controller.menuForTesting!
    #expect(menu.numberOfItems == 3)
    #expect(menu.item(at: 0)?.title == "Show")
    #expect(menu.item(at: 1)?.isSeparatorItem == true)
    #expect(menu.item(at: 2)?.title == "Quit")

    // Action dispatch flows through the represented-object identifier.
    if let quit = menu.item(at: 2) {
        _ = quit.target?.perform(Selector(("invoke:")), with: quit)
    }
    #expect(fired)
}

@MainActor
@Test func menuBarUpdateReplacesEntriesAndSetItemSwapsOneLabel() {
    let controller = RivetMenuBarController()
    controller.install(title: "Test", items: [
        .action(label: "Pause reminders", identifier: "toggle", handler: {}),
    ])
    defer { controller.remove() }

    controller.update(items: [
        .action(label: "Resume reminders", identifier: "toggle", handler: {}),
        .separator,
        .action(label: "Quit", identifier: "quit", handler: {}),
    ])
    let menu = controller.menuForTesting!
    #expect(menu.numberOfItems == 3)
    #expect(menu.item(at: 0)?.title == "Resume reminders")

    controller.setItem("toggle", label: "Pause again")
    #expect(menu.item(at: 0)?.title == "Pause again")
    // Untouched entries keep their labels.
    #expect(menu.item(at: 2)?.title == "Quit")
}

@MainActor
@Test func menuBarClickActionDetachesAndRestoresMenu() {
    let controller = RivetMenuBarController()
    var clickCount = 0
    controller.install(title: "Test", items: [
        .action(label: "Quit", identifier: "quit", handler: {}),
    ])
    defer { controller.remove() }

    let installedMenu = controller.menuForTesting
    #expect(installedMenu != nil)

    controller.setClickAction { clickCount += 1 }
    #expect(controller.menuForTesting == nil)
    #expect(controller.retainedMenuForTesting === installedMenu)

    if let button = controller.buttonForTesting, let action = button.action {
        _ = button.target?.perform(action, with: button)
    }
    #expect(clickCount == 1)

    controller.setClickAction(nil)
    #expect(controller.menuForTesting === installedMenu)
    #expect(controller.buttonForTesting?.action == nil)
}
