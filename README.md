# Screener

A small macOS utility that uses OpenAI gpt-4o-mini to automatically rename your screenshots. You can modify the prompt to suit your needs.

## Requirements
- macOS 15 (Sequoia) or later
- Xcode 15.2 or newer

## Running
1. Open `Screener.xcodeproj` in Xcode.
2. Build and run the **Screener** target.
3. When the menu bar icon appears, choose **Set Screenshots Folder...** to grant the app access to your screenshot directory.
4. Option-click the menu bar icon to quickly start or stop watching.

## OpenAI API Key
- Use **Edit API Key...** from the menu bar to enter your OpenAI API key.
- The key is stored in your user defaults and required for screenshot descriptions.

Prebuilt binaries may be added later.
