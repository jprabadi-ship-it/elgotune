# Spintune Privacy Policy

Last updated: 2026-08-02

Spintune (“the app”) tunes the behaviour of Logitech trackballs on macOS. This policy describes how the app handles information.

## What we collect

**The app collects no personal information and transmits nothing.**

Specifically, it does not:

- collect identifying information (name, email address, account details)
- run analytics, telemetry, or automatic crash reporting
- display advertising or use any data for advertising
- share or sell data to third parties

The app performs no network communication at all. Every feature behaves identically on a machine with no internet connection.

## What is stored on your Mac

The following is stored only on your own Mac and never leaves it.

| Data | Location |
|---|---|
| Button assignments, pointer and scroll settings, excluded apps | `~/Library/Preferences/` (standard macOS preferences) |
| Diagnostic log (names of connected devices, detected button events, errors) | `~/Library/Logs/Spintune.log` |

The diagnostic log exists so you can find out why a device is not being recognised. You may delete it at any time. Support may ask you to send it, but doing so is always your choice.

## Input handling

The app requires the macOS Accessibility and Input Monitoring permissions, and it observes mouse button events and trackball movement.

This is what makes the assigned actions possible. **The app does not record keystrokes**, and it neither stores nor transmits what it observes; the diagnostic log records only which button was pressed.

When you assign a keyboard shortcut, the keys you press are saved as that assignment. That is a setting you deliberately created, not a record of your typing.

## Why each permission is needed

| Permission | Purpose |
|---|---|
| Accessibility | Observing left and right clicks, and detecting press-and-hold gestures |
| Event posting | Performing the keystrokes and clicks you assign |
| Input Monitoring | Communicating with the trackball and receiving its buttons |

## Payments

Sales and payment processing are handled by an external payment provider. Your name, email address and payment details are handled by that provider; **neither the app nor its developer ever receives your card details.** The provider’s own privacy policy governs how it handles your information.

## Changes to this policy

If this policy changes, the “Last updated” date above will change and the revision will be described here.

## Contact

For questions about this policy or the app:

admin@gigowat.com

---

Spintune is an independent product and is not affiliated with Logitech International S.A. MX ERGO and ERGO M575 are trademarks of Logitech International S.A., used here solely to describe compatibility.
