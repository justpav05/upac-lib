const std = @import("std");

const database = @import("database.zig");
const ParserFSM = database.ParserFSM;
const ParserFSMError = database.ParserFSMError;

// ── Entry point ───────────────────────────────────────────────────────────────
pub fn stateStart(machine: *ParserFSM) !void {
    try machine.enter(.start);

    skipWhitespace(machine);

    return stateOpenPackage(machine);
}

// ── States ────────────────────────────────────────────────────────────────────
fn stateOpenPackage(machine: *ParserFSM) !void {
    try machine.enter(.open_package);

    try expectChar(machine, '[');
    machine.result.name = try readUntil(machine, ']');
    if (machine.result.name.len == 0) return ParserFSMError.InvalidHeader;

    if (std.mem.indexOfScalar(u8, machine.result.name, '.') != null)
        return ParserFSMError.InvalidHeader;

    skipWhitespace(machine);
    return stateAuthor(machine);
}

fn stateAuthor(machine: *ParserFSM) !void {
    try machine.enter(.author);

    try skipLabel(machine);

    machine.result.author = try readUntilSemicolon(machine);

    if (machine.result.author.len == 0) return ParserFSMError.MissingField;

    skipWhitespace(machine);

    return stateVersion(machine);
}

fn stateVersion(machine: *ParserFSM) !void {
    try machine.enter(.version);

    try skipLabel(machine);

    machine.result.version = try readUntilSemicolon(machine);

    if (machine.result.version.len == 0) return ParserFSMError.MissingField;

    skipWhitespace(machine);

    return stateLicense(machine);
}

/// Состояние 5: License: value;
fn stateLicense(machine: *ParserFSM) !void {
    try machine.enter(.license);
    try skipLabel(machine);
    machine.result.license = try readUntilSemicolon(machine);
    if (machine.result.license.len == 0) return ParserFSMError.MissingField;
    skipWhitespace(machine);
    return stateCategory(machine);
}

/// Состояние 6: Category: value;
fn stateCategory(machine: *ParserFSM) !void {
    try machine.enter(.category);
    try skipLabel(machine);
    machine.result.category = try readUntilSemicolon(machine);
    if (machine.result.category.len == 0) return ParserFSMError.MissingField;
    skipWhitespace(machine);
    return stateDescription(machine);
}

/// Состояние 7: Description: value;
fn stateDescription(machine: *ParserFSM) !void {
    try machine.enter(.description);
    try skipLabel(machine);
    machine.result.description = try readUntilSemicolon(machine);
    if (machine.result.description.len == 0) return ParserFSMError.MissingField;
    skipWhitespace(machine);
    return stateLink(machine);
}

/// Состояние 8: Link: value;
fn stateLink(machine: *ParserFSM) !void {
    try machine.enter(.link);
    try skipLabel(machine);
    machine.result.link = try readUntilSemicolon(machine);
    if (machine.result.link.len == 0) return ParserFSMError.MissingField;
    skipWhitespace(machine);
    return stateDate(machine);
}

/// Состояние 9: Date: value;
fn stateDate(machine: *ParserFSM) !void {
    try machine.enter(.date);
    try skipLabel(machine);
    machine.result.install_date = try readUntilSemicolon(machine);
    if (machine.result.install_date.len == 0) return ParserFSMError.MissingField;
    skipWhitespace(machine);
    return stateChecksum(machine);
}

/// Состояние 10: Checksum: value;
fn stateChecksum(machine: *ParserFSM) !void {
    try machine.enter(.checksum);
    try skipLabel(machine);
    machine.result.checksum = try readUntilSemicolon(machine);
    if (machine.result.checksum.len == 0) return ParserFSMError.MissingField;
    skipWhitespace(machine);
    return stateClosePackage(machine);
}

/// Состояние 11: переходное — метаданные прочитаны, ожидаем '[' файловой секции.
fn stateClosePackage(machine: *ParserFSM) !void {
    try machine.enter(.close_package);
    if (machine.currentChar() != '[') return ParserFSMError.InvalidFilesSection;
    return stateOpenFiles(machine);
}

/// Состояние 12: [PackageName.Files: {
/// Читает '[', пропускает имя и ".Files", потребляет ':', затем '{'.
fn stateOpenFiles(machine: *ParserFSM) !void {
    try machine.enter(.open_files);
    try expectChar(machine, '[');

    // Читаем до ':' — там будет "PackageName.Files"
    const header = try readUntil(machine, ':');
    if (!std.mem.endsWith(u8, header, ".Files")) return ParserFSMError.InvalidFilesSection;

    skipWhitespace(machine);
    try expectChar(machine, '{');
    skipWhitespace(machine);
    return stateFilePathStart(machine);
}

/// Состояние 13: начало пути файла.
/// Ожидает '"' для очередного файла или '}' для конца списка.
fn stateFilePathStart(machine: *ParserFSM) !void {
    try machine.enter(.file_path_start);
    skipWhitespace(machine);

    const ch = machine.currentChar() orelse return ParserFSMError.UnexpectedEndOfInput;
    if (ch == '}') return stateCloseFiles(machine);
    if (ch != '"') return ParserFSMError.UnexpectedChar;

    machine.advance(); // потребляем открывающую '"'
    return stateFilePathEnd(machine);
}

/// Состояние 14: читает путь до закрывающей '"', затем ':'.
fn stateFilePathEnd(machine: *ParserFSM) !void {
    try machine.enter(.file_path_end);

    machine.current_file_path = try readUntil(machine, '"');
    if (machine.current_file_path.len == 0) return ParserFSMError.MissingField;

    skipWhitespace(machine);
    try expectChar(machine, ':');
    skipWhitespace(machine);
    return stateFileChecksumStart(machine);
}

/// Состояние 15: начало значения чексуммы файла.
/// Чексумма может быть обёрнута в кавычки или идти голым значением.
fn stateFileChecksumStart(machine: *ParserFSM) !void {
    try machine.enter(.file_checksum_start);
    if (machine.currentChar() == '"') machine.advance();
    return stateFileChecksumEnd(machine);
}

/// Состояние 16: читает чексумму до '"' или ';',
/// сохраняет пару (current_file_path → checksum) в result.files,
/// затем возвращается в stateFilePathStart (цикл по файлам).
fn stateFileChecksumEnd(machine: *ParserFSM) !void {
    try machine.enter(.file_checksum_end);

    const start = machine.pos;
    while (machine.pos < machine.data.input.len) {
        const ch = machine.data.input[machine.pos];
        if (ch == '"' or ch == ';') break;
        machine.pos += 1;
    }
    if (machine.pos >= machine.data.input.len) return ParserFSMError.UnexpectedEndOfInput;

    const cs = std.mem.trim(u8, machine.data.input[start..machine.pos], " \t");
    if (cs.len == 0) return ParserFSMError.MissingField;

    if (machine.currentChar() == '"') machine.advance(); // закрывающая '"'
    if (machine.currentChar() == ';') machine.advance(); // обязательная ';'

    try machine.result.files.put(machine.current_file_path, cs);
    skipWhitespace(machine);

    // Цикл: следующий файл или конец списка
    return stateFilePathStart(machine);
}

/// Состояние 17: закрывает список файлов — потребляет '}' и ']'.
fn stateCloseFiles(machine: *ParserFSM) !void {
    try machine.enter(.close_files);

    try expectChar(machine, '}');
    skipWhitespace(machine);
    try expectChar(machine, ']');
    skipWhitespace(machine);
    return stateDone(machine);
}

/// Состояние 18: конечное состояние.
fn stateDone(machine: *ParserFSM) !void {
    try machine.enter(.done);
}

// ── Private helpers ───────────────────────────────────────────────────────────

/// Пропускает пробелы, табуляции, переносы строк.
fn skipWhitespace(machine: *ParserFSM) void {
    while (machine.pos < machine.data.input.len) {
        switch (machine.data.input[machine.pos]) {
            ' ', '\t', '\r', '\n' => machine.pos += 1,
            else => break,
        }
    }
}

fn skipLabel(machine: *ParserFSM) !void {
    while (machine.pos < machine.data.len and
        machine.data[machine.pos] != ':')
    {
        machine.pos += 1;
    }
    if (machine.pos >= machine.data.len) return ParserFSMError.UnexpectedEndOfInput;
    machine.pos += 1; // потребляем ':'
    skipWhitespace(machine);
}

/// Читает символы до `delim` (не включая), потребляет `delim`.
/// Возвращает срез в оригинальном буфере с обрезанными пробелами.
/// При отсутствии delimiter возвращает UnexpectedEndOfInput.
fn readUntil(machine: *ParserFSM, delim: u8) ![]const u8 {
    const start = machine.pos;
    while (machine.pos < machine.data.input.len and
        machine.data.input[machine.pos] != delim)
    {
        machine.pos += 1;
    }
    if (machine.pos >= machine.data.input.len) return ParserFSMError.UnexpectedEndOfInput;
    const slice = std.mem.trim(u8, machine.data.input[start..machine.pos], " \t\r\n");
    machine.pos += 1; // потребляем delimiter
    return slice;
}

/// Читает до ';', обрезает пробелы, потребляет ';'.
fn readUntilSemicolon(machine: *ParserFSM) ![]const u8 {
    return readUntil(machine, ';');
}

/// Проверяет, что текущий символ равен `expected`, потребляет его.
/// Если символ другой — UnexpectedChar; если конец буфера — UnexpectedEndOfInput.
fn expectChar(machine: *ParserFSM, expected: u8) !void {
    const ch = machine.currentChar() orelse return ParserFSMError.UnexpectedEndOfInput;
    if (ch != expected) return ParserFSMError.UnexpectedChar;
    machine.advance();
}
