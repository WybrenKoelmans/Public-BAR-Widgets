# How to Contribute a New Widget

There are **two ways** to contribute:

1. **Direct Contribution:**
  - Add your widget directly to this repository under `Widgets/community/<your_widget_id>` (simplest) by forking this repository. Create and maintain your widgets in your fork, and make a pull request to the main repository to update your widget in the hub.

2. **External Repository:**
  - Maintain your own repository and link it to this repository by adding a git submodule.
    - Fork this repository and add a git submodule to your own repository, then create a PR to add your submodule to the hub.
    - **Note:** If you have multiple widgets in the same repository, *each update* will require *all* widgets to be approved at the same time, which can slow down the process.


# Required Widget Structure

```
<your_widget_id>/
  ├─ <your_widget_id>.lua   # Main widget code
  ├─ cover.png              # PNG image (~400x400) showcasing your widget
  ├─ README.md              # Detailed explanation of your widget
  ├─ manifest.json          # Technical data about your widget (see below)
  └─ <other_files_allowed_up_to_a_point> # You are not limited to a single file, but try to keep it within reason
```


Please follow the naming conventions used by other widgets. While there are no strict rules, use prefixes such as `gui_`, `cmd_`, or `unit_` to indicate the scope of your widget. Use `gui_lower_snake_case` for consistency.



## manifest.json

Ensure your `id` is globally unique; avoid using common or generic IDs.

Your `manifest.json` must include the following fields:

```json
{
  "id": "<your_widget_id>",
  "display_name": "A Pretty Display Name",
  "author": "YourUserName",
  "discord_link": "https://discord.com/channels/12345/12345",
  "github_link": "https://github.com/beyond-all-reason/Beyond-All-Reason/pull/5309",
  "description": "A SHORT description that summarizes your widget."
}
```

# What is Allowed?

Currently, all widgets are manually vetted and moderated by a group of contributors. Widgets that are clear violations of the Game Design Document will be rejected. Please do not engage in discussion about moderation in this repository. Instead, use the appropriate channels on the BAR Discord server.
