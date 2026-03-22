# Squad Selection

**Automagical squad creation and proximity-based squad selection widget for [Beyond All Reason](https://www.beyondallreason.info/).**

*tldr: select some units, right-click to create a squad, then ctrl+click to select the closest squad.*

## Why?

Control groups are limited in number and require manual assignment, auto-groups select units across the entire map which is not always what we want, selectboxes are imprecise and can be difficult to use in the heat of battle.  
**Squad Selection** fills the gap: it tracks groups of units you're actually using together, then lets you re-select them based on which squad is closest to your mouse cursor.  
Works alongside all the other selection methods.

Jump straight to [installation](#installation) if you want to get going right away.

## How it works

Every combat unit (mobile + armed, without build options) starts in a **reserve squad** for its domain (land, air, or naval).  

**Creating squads:** Select some units and **right-click** (with no modifier keys held). Those units are pulled out of their current squads into a new one.  

The reason for the "no modifiers" requirement is that it allows you to use units without creating a new squad if that's what you want. For example, you can send multiple squads together to a target with shift and right mouse button which wouldn't merge them into one squad since shift is a modifier. Then you can use squad selection to easily select each squad individually near the target for good flanking micro.

**Selecting squads:** Move your mouse cursor near the squad you want selected, then use a hotkey or ctrl+leftclick to select that squad (the closest).  
Repeatedly selecting when the closest full squad is already selected **cycles** to the next closest squad (this feature can be disabled).  
*Note: the ctrl modifier is technically not required, but the normal selectbox would interfere without it.*  

There is also a **filtered select** option that only selects the unit types from your current selection, or the closest unit's type if nothing is selected. This is hotkey or alt+ctrl+leftclick.

Both selection methods can be used with shift to append to the current selection instead of replacing it.  

*Note: the left mouse selection methods can be disabled if you prefer to use hotkeys exclusively (write `/luaui squad_setting toggle leftClickSelectsSquad` in chat (saved, you don't need to re-enter it each game)).*

Each squad is labeled with a colored letter above its units so you can see which units belong together at a glance. (There's also an experimental convex hull visualization mode and two other modes in the works)

### Hotkeys

If you want to use hotkeys instead of mouse (or in addition to), you can bind the following actions in your `uikeys.txt`:

```
bind           sc_b  closest_squad_select
bind     Shift+sc_b  closest_squad_select append
bind       Alt+sc_b  closest_squad_select_filtered
bind Alt+Shift+sc_b  closest_squad_select_filtered append
```
*(change `sc_b` to your preferred key)*


| Action                                               | What it does                                                                                                                         |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `closest_squad_select`                               | Selects the entire squad closest to the cursor                                                                                       |
| `closest_squad_select append`                        | Appends the closest squad to the current selection                                                                                   |
| `closest_squad_select_filtered`                      | Selects only the unit types (from your current selection or closest unit if nothing is selected) in the closest squad                |
| `closest_squad_select_filtered append`               | Same, but appends to selection                                                                                                       |
| `squad_create_toggle`                                | Toggles right-click squad creation on/off (see next section)                                                                         |
| `squad_create`                                       | Creates a squad from the current selection (useful if you disable right-click squad creation) or you want to assign a lab to a squad |
| `squad_select_group N`                               | Select squad ∩ control group N closest to cursor                                                                                     |
| `squad_select_portion [append] <steps...>`           | Select a portion of the closest squad                                                                                                |
| `squad_select_portion_filtered [append] <steps...>`  | Same, but filtered by unit type                                                                                                      |
| `squad_select_portion_group <N> [append] <steps...>` | Same, but limited to squad ∩ control group N (probably will be removed)                                                              |

### Mouse controls

With `leftClickSelectsSquad` enabled (default), clicking on empty ground triggers squad selection:

| Click               | Action                          |
| ------------------- | ------------------------------- |
| **Ctrl+click**      | Select closest squad (replace)  |
| **Shift+click**     | Select closest squad (append)   |
| **Alt+Ctrl+click**  | Filtered squad select (replace) |
| **Alt+Shift+click** | Filtered squad select (append)  |

Mouse squad selections are skipped when clicking directly on a unit or when an active command is pending (fight, patrol, build placement, etc.).

**Right-click** (no modifiers) with a selection creates a squad from selected combat units.

### Cycling

When you already have a full squad selected (or all matching types for filtered select), the action automatically excludes your current selection and finds the *next* closest squad. This lets you cycle through squads by pressing the same key repeatedly (can be disabled via `cyclingToNextSquad` in data/LuaUi/Config/BYAR.lua -> Squad Selection section).

### Filtered selection

Filtered selection is useful with some playstyles but unnecessary for others. If your main goal is to just create squads based on unit types (thugs, grunts, etc.), then you could just use autogroups or any kind of selection method to select the thugs, then right-click to create a squad for them, same with grunts. Then you can use the normal closest squad select to get the squad of thugs or grunts, or better yet, cycle between them.

### Squad creation toggle + hotkey

Right-click squad creation can be toggled on/off. (Detailed explanation for the why soon). 

There's also an action to create a squad on demand (without needing right-click).


| Action                | What it does                               |
| --------------------- | ------------------------------------------ |
| `squad_create`        | Creates a squad from the current selection |
| `squad_create_toggle` | Toggles right-click squad creation on/off  |

### Control group intersection

Select the intersection of a squad and a control group. Uses the closest unit from the control group to determine which squad, then selects only the units that are in both that squad and the control group.

Suggested keybinds:
```
bind Shift+Meta+1 squad_select_group 1 append //shift+space+1
bind Meta+1 squad_select_group 1 //space+1
bind Shift+Meta+2 squad_select_group 2 append
bind Meta+2 squad_select_group 2
...
```

| Action                        | What it does                             |
| ----------------------------- | ---------------------------------------- |
| `squad_select_group N`        | Select squad ∩ group N closest to cursor |
| `squad_select_group N append` | Same, but appends to selection           |

### Factory / lab assignment

By default, newly built combat units go into a domain reserve squad (land, air, or naval). You can assign factories to their own reserve squad so their units are tracked separately.

**How to use:** Select one or more factories and press the `squad_create` hotkey. A new factory reserve squad is created and all selected factories are assigned to it. Units built by those factories will go into that squad instead of the domain reserve.

Factory reserve squads are shown with a white label decorated with domain symbols (e.g. `-A-` for a land factory, `^B^` for air, `~C~` for naval). Multiple factories can share one squad.

**Example use case:** You have 3 bot labs, 2 producing cheap spam units for distraction, 1 producing expensive units you want to micro. Assign the expensive lab to its own squad, then easily select just those units when you need them.

### Portion selection

Select a portion of a squad, sorted by distance to the mouse cursor. Define step values in the hotkey bind. Each press advances to the 'next step' until max value.

Step values: `0` selects 1 unit, values between 0 and 1 are percentages (e.g. `0.5` = 50%), values above 1 are fixed counts (e.g. `5` = 5 units).

**Replace mode** replaces selection with the closest N units to your cursor. Past the last step, it keeps selecting the last step's count.

**Append mode** appends the closest N *unselected* units to your selection, N is based on the step's value and number of selected units. Append always targets the closest squad, so you can append from a different squad than what's already selected.

In both cases N is based on the step's value and number of selected units in the closest squad.

I know the above sounds a bit complicated and honestly it is, so here's a few examples to clarify:

- If steps is simply `0`, then in replace mode you get the closest unit to your cursor with each press. In append mode you keep the previously selected units and add the next closest unselected unit with each press. That number can be of course 10 or anything.
- If steps is `0.5`, then that's just 50%. 
  - In replace mode if the closest squad has 20 units, the first press selects 10, the second press still selects 10 but maybe another 10 depending on proximity. 
  - In append mode the first press selects 10, the second press adds 10 more unselected units. If you point at another squad which has 30 units, then another press will add 15 from that squad. 
- If the steps is `5 10`, 
  - Then in replace mode the first press selects the 5 closest units, the second press replaces that selection with the 10 closest, then each press after that also replaces the selection with the 10 closest.
  - In append mode the first press selects 5, the second press adds 10 to it. Each press after that adds 10 more unselected units to the selection.


| Action                                               | What it does                                 |
| ---------------------------------------------------- | -------------------------------------------- |
| `squad_select_portion [append] <steps...>`           | Select a portion of the closest squad        |
| `squad_select_portion_filtered [append] <steps...>`  | Same, but filtered by unit type              |
| `squad_select_portion_group <N> [append] <steps...>` | Same, but limited to squad ∩ control group N |

## Installation

Download and drop [squad-selection.lua](https://raw.githubusercontent.com/MadeByGabe/squad-selection/refs/heads/main/squad-selection.lua) into your `data/LuaUI/Widgets/` directory.  
Enable it in-game with **F11** (widget list) or just write this into chat:

```
/luaui togglewidget Squad Selection
```

### Configuration

For now you can change settings in-game via chat commands:


```
/luaui squad_setting toggle rightClickSquadCreate
/luaui squad_setting toggle cyclingToNextSquad
/luaui squad_setting set visualizationMode convexHull
/luaui squad_setting set visualizationMode coloredLabel
```

These changes persist.


| Setting                 | Default          | Description                                     |
| ----------------------- | ---------------- | ----------------------------------------------- |
| `leftClickSelectsSquad` | `true`           | Modifier+click on empty ground selects squads   |
| `cyclingToNextSquad`    | `true`           | Cycle to next squad when full squad is selected |
| `rightClickSquadCreate` | `true`           | Right-click squad creation is active            |
| `visualizationMode`     | `"coloredLabel"` | `"coloredLabel"` or `"convexHull"`              |



| Action                            | What it does                          |
| --------------------------------- | ------------------------------------- |
| `squad_setting toggle <key>`      | Toggles a boolean setting             |
| `squad_setting set <key> <value>` | Sets a setting to a specific value    |
| `squad_setting get <key>`         | Prints the current value of a setting |

*Note: control groups have a nice feature when we double tap their number key to move the camera to that group. Something similar for squads should be possible but in the meantime you can bind `viewselection` to a hotkey for a similar effect (it centers the camera on your current selection).*

### Hotkey setup

Settings -> Control -> Change keybind preset to `custom` (from grid)

This creates an `uikeys.txt` file in the game's data folder. 

Open that file with any text editor and add the following lines to the end of the file:


```
bind Shift+Meta+1 squad_select_group 1 append
bind Meta+1 squad_select_group 1
//...

unbind Alt+sc_c blueprint_create

unbind Any+sc_c gridmenu_key 1 3
bind sc_c gridmenu_key 1 3
bind Shift+sc_c gridmenu_key 1 3

bind Alt+sc_c squad_create
bind sc_c closest_squad_select
bind shift+sc_c closest_squad_select append
bind Ctrl+sc_c squad_select_portion 0 0.5
bind Ctrl+shift+sc_c squad_select_portion 3 10 append
bind Ctrl+Meta+sc_c squad_create_toggle


unbind Any+sc_x gridmenu_key 1 2
bind sc_x gridmenu_key 1 2
bind Shift+sc_x gridmenu_key 1 2

bind sc_x closest_squad_select_filtered
bind shift+sc_x closest_squad_select_filtered append
bind Ctrl+sc_x squad_select_portion_filtered 0 0.25 0.5 0.75 1
bind Ctrl+shift+sc_x squad_select_portion_filtered 5 10 append

bind Alt selectbox_same
bind sc_b viewselection
```

Then in game write `/keyreload` in chat to apply the changes if the game is already running.

#### Explanation

`x` and `c` are essentially free keys. They are used to start the unit queue in labs but that still can be used with the above rebind (turn on settings -> control -> Factory build mode hotkeys). 

With these changes `c` becomes squad selection, with shift it's append, with ctrl it's squad portion selection. Finally with alt it's squad creation.  
`squad_create` is needed to assign labs to squads and also useful if you disable the right click squad creation with settings or temporarily with the `ctrl+space+c` hotkey.

`x` is pretty much the same except filtered selection.

`Space+1` is the group intersection selection for group 1, feel free to add more lines for more groups, or even rebind to different keys (maybe even replace `group select 1` and bind that to space+1).

I added two bonus hotkeys. Hold `Alt` while you have a unit selected to draw a selectbox. That selectbox will select only the same unit types as the currently selected units. This is very useful together with the squad selection though it's less important now that we have portion selection. 

I also bound `viewselection` to `b` for a quick camera centering on your current selection since that's not yet part of this widget. 

### Guide to learn how it works

Set up the hotkeys as described above, then launch a skirmish game against an inactive ai. 

Build a bot lab and an air lab (you can increase speed with `alt++` and decrease with `alt+-`) to do it very quickly.  

Make some Thugs, Grunts, and Shurikens. Assign all three unit types to autogroup 1 with `alt+1`. 

Now pressing `space+1` will select either the Thugs and Grunts, or the Shurikens, depending on which domain reserve squad is closer to your mouse cursor.  
If you press it again, you will get the units from the other squad with cycling, you can disable that if you don't want it.

Press `c` to select the closest squad to your cursor, so either all land domain reserve units or the shurikens. Again cycling applies if you press it again.  
Press `shift+c` to append the other squad to your selection.  

Click on the ground to unselect everything and press `x` to select the closest unit's type from its squad. So for example either Thugs, or Grunts. With shift you could add the same type of units from other squads but you don't have any other that have them (if you followed these instructions).

Click on the ground to unselect everything and press `ctrl+c` to select one unit from the closest squad. Press it again to select half of them from that squad. Press again to reselect the same count but re-sorted by your current cursor position.
Press `ctrl+shift+c` to append 10 units to your selection from the same squad or to add 3 from other squads. 

Same with `x` but filtered by type and my hotkey example had different step values for `x`. 

Note, you can use the closest unit selection (`ctrl+c` once) and then draw a selectbox with alt to select the same type of unit.

Now build two vehicle plants and spam some rascals/rovers. Note that `c` will select the closest squad which if you followed the instructions should be the land domain reserve with the thugs, grunts and rascals.  
Select the two vehicle plants and press `alt+c` to assign a squad to that. `c` will now select either Thugs and Grunts, or the Rascals since the rascals are now in a factory reserve squad. 

Select some units and right click. Those units are now a squad. Everything above applies. If you don't want this behavior you can disable the right click squad creation and just use the `alt+c` hotkey to create squads from selected units when you want to.

If you don't want to bother with `c` and `x`, you can use `ctrl+leftclick` and `alt+ctrl+leftclick` respectively. Both can be used with shift to append instead of replace.

## Credits

- **yyyy**: original concept and the [Fassst Selectionssss](https://kk1ff.com/bar/select.lua) prototype
- **Baldric**: this implementation
- Built with **assistance** from [Claude Code](https://claude.ai/code)

## License

GNU GPL, v2 or later.