// Copyright (c) 2025 Denver Hoggatt.
// All rights reserved.
//
// This software is licensed under terms that can be found
// in the LICENSE file in the root directory of this software component.
// If no LICENSE file comes with this software, it is provided AS-IS.
//
//! Denver's Integrated Shell (dish). This is a simple command line interface intended for use in
//! embedded systems. It's intended to be lightweight, efficient, and have no external dependencies.
//!

// ----------------------------- Public Constants and Variables ------------------------------------

pub const NEWLINE_ACTION: []const u8 = "newline";
pub const UP_ARROW_ACTION: []const u8 = "uparrow";
pub const DOWN_ARROW_ACTION: []const u8 = "downarrow";
pub const BACKSPACE_ACTION: []const u8 = "backspace";
pub const COMPLETE_ACTION: []const u8 = "complete";

pub const Output = *const fn ([]const u8) void;
pub const Input = *const fn ([]const u8) void;
pub const Exec = *const fn ([]const []const u8, Output) void;

// ---------------------------- Private Constants and Variables ------------------------------------

const VERSION: []const u8 = "0.1.0";

const MAX_CMDS: u32 = 64;
const MAX_CMD_LEN: u32 = 128;
const HISTORY_LEN: u32 = 32;
const MAX_TRIG_LEN: u32 = 32;
const MAX_PROMPT_LEN: u32 = 32;
const MAX_NEWLINE_LEN: u32 = 16;
const HELP_LEN: u32 = 128;

const HELP_NAME: []const u8 = "help";
const VERSION_NAME: []const u8 = "version";

const DishErrors = error{
    CommandBufferFull,
    NullOutput,
    InvalidCommand,
    InvalidName,
    InvalidNewLine,
    InvalidLength,
};

const actionFunc = *const fn () void;

const Action = struct {
    name: []const u8 = &[_]u8{},
    triggerBuf: [MAX_TRIG_LEN]u8 = [_]u8{0} ** MAX_TRIG_LEN,
    trigger: []const u8 = &[_]u8{},
    action: actionFunc = default_action,
    echo: bool = false,
};

const DishCommand = struct {
    nameBuf: [MAX_CMD_LEN]u8 = [_]u8{0} ** MAX_CMD_LEN,
    name: []const u8 = &[_]u8{},
    helpBuf: [HELP_LEN]u8 = [_]u8{0} ** HELP_LEN,
    help: []const u8 = &[_]u8{},
    func: Exec = default_cmd,
    enabled: bool = false,
};

const helpCmd: DishCommand = .{
    .name = HELP_NAME,
    .help = "Prints out a list of commands",
    .func = help_cmd,
    .enabled = true,
};

const versionCmd: DishCommand = .{
    .name = VERSION_NAME,
    .help = "Version of dish",
    .func = version_cmd,
    .enabled = true,
};

const actionList: []const Action = &[_]Action{
    Action{
        .name = NEWLINE_ACTION,
        .trigger = &[_]u8{'\n'},
        .action = exec_cmd,
        .echo = true,
    },
    Action{
        .name = UP_ARROW_ACTION,
        .trigger = &[_]u8{ 0x1B, '[', 'A' },
        .action = load_prev_line,
        .echo = false,
    },
    Action{
        .name = DOWN_ARROW_ACTION,
        .trigger = &[_]u8{ 0x1B, '[', 'B' },
        .action = load_next_line,
        .echo = false,
    },
    Action{
        .name = BACKSPACE_ACTION,
        .trigger = &[_]u8{0x7F},
        .action = backspace,
        .echo = false,
    },
    Action{
        .name = COMPLETE_ACTION,
        .trigger = &[_]u8{0x09},
        .action = attempt_completion,
        .echo = false,
    },
};

var output: ?Output = null;

var dishCmds: [MAX_CMDS]DishCommand = [_]DishCommand{helpCmd} ++
    [_]DishCommand{versionCmd} ++
    ([_]DishCommand{DishCommand{}} ** (MAX_CMDS - 2));

var currentLineBuf: [MAX_CMD_LEN]u8 = undefined;
var currentLine: []u8 = currentLineBuf[0..0];

var historyStrs: [HISTORY_LEN][MAX_CMD_LEN]u8 = undefined;
var historyLens: [HISTORY_LEN]u32 = .{0} ** HISTORY_LEN;
var historyEnd: u32 = 0;
var historyCurrent: u32 = 0;

var promptBuf: [MAX_PROMPT_LEN]u8 = .{'>'} ++ (.{0} ** (MAX_PROMPT_LEN - 1));
var promptStr: []u8 = promptBuf[0..1];

var newlineBuf: [MAX_NEWLINE_LEN]u8 = .{ '\r', '\n' } ++ (.{0} ** (MAX_NEWLINE_LEN - 2));
var newlineStr: []u8 = newlineBuf[0..2];

// ----------------------------------- Public Functions --------------------------------------------

/// Registers a command.
///
pub fn register_cmd(name: []const u8, help: []const u8, func: Exec) !void {
    if (name.len >= MAX_CMD_LEN) {
        return DishErrors.InvalidName;
    }

    const idx: u32 = try get_index(name, true);
    @memcpy(dishCmds[idx].nameBuf[0..name.len], name[0..name.len]);
    dishCmds[idx].name = dishCmds[idx].nameBuf[0..name.len];
    @memcpy(dishCmds[idx].helpBuf[0..help.len], help[0..help.len]);
    dishCmds[idx].help = dishCmds[idx].helpBuf[0..help.len];
    dishCmds[idx].func = func;
    dishCmds[idx].enabled = true;
}

/// Registers the callback function that dish will call when outputting.
///
pub fn register_output(outFunc: ?Output, givePrompt: bool) !void {
    output = outFunc;
    if (givePrompt) {
        output_str(promptStr);
    }
}

/// Returns the function used to input data into dish.
///
pub fn register_input() Input {
    return receive_input;
}

/// Registers an action that dish will take on the given trigger.
///
pub fn register_action(name: []const u8, trigger: []const u8) !void {
    if (trigger.len > MAX_TRIG_LEN) {
        return DishErrors.InvalidLength;
    }

    for (actionList) |*action| {
        if (str_eq(name, action.*.name)) {
            @memcpy(action.*.triggerBuf[0..trigger.len], trigger[0..trigger.len]);
            action.*.trigger = action.*.triggerBuf[0..trigger.len];
        }
    }
}

/// Registers the prompt used by dish to proimpt input. Default is '>'.
///
pub fn register_prompt(newPrompt: []const u8) void {
    const cpy_len: u32 = @min(newPrompt.len, MAX_PROMPT_LEN);

    @memcpy(promptBuf[0..cpy_len], newPrompt[0..cpy_len]);
    promptStr = promptBuf[0..cpy_len];
}

/// Registers the newline terminator used when outputting a string. This is different from the
/// newline action used to trigger a command.
///
pub fn register_newline(newNewLine: []const u8) void {
    const cpy_len: u32 = @min(newNewLine.len, MAX_NEWLINE_LEN);

    @memcpy(newlineBuf[0..cpy_len], newNewLine[0..cpy_len]);
    newlineStr = newlineBuf[0..cpy_len];
}

// ---------------------------------- Private Functions --------------------------------------------

fn default_cmd(_: []const []const u8, _: Output) void {}

fn default_action() void {}

fn help_cmd(_: []const []const u8, _: Output) void {
    for (dishCmds) |cmd| {
        if (cmd.enabled) {
            output_str(cmd.name);
            output_str(": ");
            output_str(cmd.help);
            newline();
        }
    }
}

fn version_cmd(_: []const []const u8, _: Output) void {
    output_str("Dish Version: ");
    output_str(VERSION);
    newline();
}

fn hash(cmd: []const u8) u32 {
    var sum: u32 = 0;
    for (cmd) |c| sum += @intCast(c);
    return sum % MAX_CMDS;
}

fn get_index(cmd: []const u8, getIfEmpty: bool) !u32 {
    if (str_eq(cmd, HELP_NAME)) {
        return 0;
    }

    const start = hash(cmd);

    var i: u32 = 0;
    while (i < MAX_CMDS) : (i += 1) {
        const idx = (start + i) % MAX_CMDS;
        const slot: *DishCommand = &dishCmds[idx];

        if (getIfEmpty and !slot.*.enabled) {
            return idx; // Told to return empty indexes, return it
        } else if (!getIfEmpty and !slot.*.enabled) {
            return DishErrors.InvalidName; // Otherwise, the cmd is not in the list
        }

        if (str_eq(cmd, slot.*.name)) {
            return idx;
        }
    }

    return DishErrors.InvalidName;
}

fn str_eq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) {
        return false;
    }

    var i: u32 = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) {
            return false;
        }
    }

    return true;
}

fn delete_trailing_newline() void {
    if (newlineStr.len > currentLine.len) {
        return;
    }

    currentLine = currentLine[0..(currentLine.len - newlineStr.len)];
}

fn delete_trailing_spaces() void {
    while ((currentLine.len > 0) and (currentLine[currentLine.len - 1] == ' ')) {
        currentLine = currentLine[0..(currentLine.len - 1)];
    }
}

fn prompt() void {
    output_str(promptStr);
}

fn newline() void {
    output_str(newlineStr);
}

fn output_str(str: []const u8) void {
    if (output) |call_output| {
        call_output(str);
    }
}

fn output_line(str: []const u8) void {
    output_str(str);
    newline();
}

fn output_char(char: u8) void {
    const str: []const u8 = &[_]u8{char};
    output_str(str);
}

fn add_to_current_line(char: u8) void {
    if (currentLine.len > (MAX_CMD_LEN - 1)) {
        return; // Just stop adding if the buffer is full.
    }

    currentLineBuf[currentLine.len] = char;
    currentLine = currentLineBuf[0..(currentLine.len + 1)];
}

fn erase_line() void {
    output_char('\r');

    // Clear to end of line
    output_char(0x1B);
    output_char('[');
    output_char('K');

    prompt();
}

fn clear_line() void {
    currentLine = currentLineBuf[0..0];
}

fn save_line() void {
    const lineLen: u32 = @min(currentLine.len, MAX_CMD_LEN); // Should never be max
    historyLens[historyEnd] = lineLen;
    @memcpy(historyStrs[historyEnd][0..lineLen], currentLine[0..lineLen]);

    historyEnd = (historyEnd + 1) % HISTORY_LEN;
}

fn backspace() void {
    if (currentLine.len < (promptStr.len + 1)) {
        // Backspaced into prompt. Remove backspace character from line, then do nothing.
        currentLine = currentLine[0..(currentLine.len - 1)];
        return;
    }

    // Otherwise, backspace, then delete, then update current line representation.
    output_char(0x8);
    output_char(127);
    output_char(0x8);
    currentLine = currentLine[0..(currentLine.len - 2)];
}

fn load_next_line() void {
    output_char(0x1B); // Respond to arrow
    output_char('[');
    output_char('K');

    const stop: u32 = if (historyEnd == 0) (HISTORY_LEN - 1) else (historyEnd - 1) % HISTORY_LEN;
    if (historyCurrent == stop) {
        currentLine = currentLineBuf[0..0];
        erase_line(); // Erase since we want to clear the line, but there's nothing to load
        return; // Reached end of history list
    }

    historyCurrent = (historyCurrent + 1) % HISTORY_LEN;

    const lineLen: u32 = @min(historyLens[historyCurrent], MAX_CMD_LEN);
    const line: []const u8 = historyStrs[historyCurrent][0..lineLen];

    erase_line();
    @memcpy(currentLineBuf[0..lineLen], line[0..lineLen]);
    currentLine = currentLineBuf[0..lineLen];
    output_str(currentLine);
}

fn load_prev_line() void {
    output_char(0x1B); // Respond to arrow
    output_char('[');
    output_char('K');

    const stop: u32 = (historyEnd + 1) % HISTORY_LEN;
    if (historyCurrent == stop) {
        return; // Reached start of history list
    }

    if (historyCurrent == 0) {
        historyCurrent = HISTORY_LEN - 1;
    } else {
        historyCurrent = (historyCurrent - 1) % HISTORY_LEN;
    }

    const lineLen: u32 = @min(historyLens[historyCurrent], MAX_CMD_LEN);
    const line: []const u8 = historyStrs[historyCurrent][0..lineLen];

    erase_line();
    @memcpy(currentLineBuf[0..lineLen], line[0..lineLen]);
    currentLine = currentLineBuf[0..lineLen];
    output_str(currentLine);
}

fn exec_cmd() void {
    var args: [MAX_CMD_LEN][]const u8 = undefined;

    delete_trailing_newline();
    delete_trailing_spaces();

    add_to_current_line(' '); // To delimit the last word

    var wordCount: u32 = 0;
    var j: usize = 0;
    for (currentLine, 0..) |c, i| {
        if (c != ' ') {
            continue;
        }

        args[wordCount] = currentLine[j..i];
        j = i + 1;
        wordCount += 1;
    }

    wordCount = @min(wordCount, args.len);

    const currentCmd: []const u8 = args[0];
    const currentArgs: []const []const u8 =
        if (wordCount > 1) args[1..wordCount] else args[1..1];

    const matchingIdx: u32 = get_index(currentCmd, false) catch MAX_CMDS;
    if (matchingIdx < MAX_CMDS) {
        dishCmds[matchingIdx].func(currentArgs, output_str);
    } else if (currentCmd.len != 0) {
        output_line("Unrecognized Command");
    }

    if (currentCmd.len != 0) {
        delete_trailing_spaces(); // Delete the added space
        save_line();
    }

    clear_line();
    historyCurrent = historyEnd;

    prompt();
}

fn ends_with(str: []const u8) bool {
    if (currentLine.len < str.len) {
        return false;
    }

    for (currentLine[(currentLine.len - str.len)..], 0..) |c, i| {
        if (c != str[i]) {
            return false;
        }
    }

    return true;
}

fn find_action() ?*const Action {
    var retVal: ?*const Action = null;

    inline for (actionList) |*action| {
        if (ends_with(action.trigger)) {
            retVal = action;
        }
    }

    return retVal;
}

fn receive_input(input_str: []const u8) void {
    for (input_str) |c| {
        add_to_current_line(c);

        if (find_action()) |action| {
            if (action.echo) {
                output_char(c);
            }
            action.action();
        } else {
            output_char(c);
        }
    }
}

fn attempt_completion() void {
    var matches: [MAX_CMDS][]const u8 = undefined;

    var numMatches: u32 = 0;
    for (dishCmds) |cmd| {
        if (numMatches == MAX_CMDS) {
            break;
        }

        if (currentLine.len == 0) {
            break;
        }

        if (currentLine.len > cmd.name.len) {
            break;
        }

        var i: u32 = 0;
        while (i < currentLine.len) : (i += 1) {
            if (currentLine[i] != cmd.name[i]) {
                break;
            }
        }

        if (i == currentLine.len) // did not break early, match found
        {
            matches[numMatches] = cmd.name;
            numMatches += 1;
        }
    }

    if (numMatches == 0) {
        return;
    }

    if (numMatches > 1) {
        newline();
        var i: u32 = 0;
        while (i < numMatches) : (i += 1) {
            output_str(matches[i]);
            newline();
        }
        prompt();
        output_str(currentLine);
        return;
    }

    if (numMatches == 1) {
        output_str(matches[0][currentLine.len..]);
    }
}

// End of file
