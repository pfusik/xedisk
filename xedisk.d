// Written in the D programming language

/*
xedisk.d - xedisk console UI
Copyright (C) 2010-2012 Adrian Matoga

xedisk is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

xedisk is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with xedisk.  If not, see <http://www.gnu.org/licenses/>.
*/

import std.stdio;
import std.regex;
import std.range;
import std.algorithm;
import std.string;
import std.exception;
import std.conv;
import std.getopt;
import std.file;
import std.path;
import xe.disk;
import xe.disk_impl.all;
import xe.fs;
import xe.fs_impl.all;
import xe.exception;
import xe.streams;

version(unittest)
{
	import xe.test;

	XeEntry findOnDisk(string disk, string file)
	{
		return XeFileSystem.open(XeDisk.open(new FileStream(File(disk))))
			.getRootDirectory().find(file);
	}
}

auto parseSectorRange(in char[] s, int max)
{
	auto m = match(s, "^([0-9]+)?(-([0-9]+)?)?$");
	enforce(!!m, "Invalid range syntax");
	int end;
	int begin = m.captures[1].length ? to!int(m.captures[1]) : 1;
	if (m.captures[2].length)
		end = m.captures[3].length ? to!int(m.captures[3]) : max;
	else
		end = begin;
	enforce(begin <= end && begin >= 1 && end <= max, "Invalid sector range");
	return iota(begin, end + 1);
}

unittest
{
	mixin(Test!"parseSectorRange (1)");
	assertThrown(parseSectorRange("120-d", 23));
	assert (parseSectorRange("120", 720).length == 1);
	assert (parseSectorRange("600-", 720).length == 121);
	assert (parseSectorRange("120-123", 720).length == 4);
	assert (parseSectorRange("-5", 720).length == 5);
	assert (parseSectorRange("-", 720).length == 720);
}

struct ScopedHandles
{
	~this()
	{
		if (fs) { destroy(fs); fs = null; }
		if (disk) { destroy(disk); disk = null; }
		if (table) { destroy(table); table = null; }
		if (stream) { destroy(stream); stream = null; }
		file.close();
	}

	XeFileSystem fs;
	XeDisk disk;
	XePartitionTable table;
	RandomAccessStream stream;
	File file;
}

enum OpenMode
{
	ReadOnly = 0,
	ReadWrite = 1,
	Create = 2
}
immutable cOpenModes = [ "rb", "r+b", "w+b" ]; // must match OpenMode!

ScopedHandles openFileStream(string fileName, OpenMode mode)
{
	ScopedHandles sh;
	final switch (mode)
	{
	case OpenMode.ReadOnly, OpenMode.ReadWrite, OpenMode.Create:
		sh.file = File(fileName, cOpenModes[mode]); break;
	}
	sh.stream = new FileStream(sh.file);
	return sh;
}

ScopedHandles openDisk(string fileName, OpenMode mode)
{
	assert(mode != OpenMode.Create);
	auto sh = openFileStream(fileName, mode);
	sh.disk = XeDisk.open(sh.stream, mode == OpenMode.ReadOnly
		? XeDiskOpenMode.ReadOnly : XeDiskOpenMode.ReadWrite);
	return sh;
}

ScopedHandles createDisk(string fileName, string diskType, uint sectors, uint sectorSize)
{
	auto sh = openFileStream(fileName, OpenMode.Create);
	sh.disk = XeDisk.create(sh.stream, diskType, sectors, sectorSize);
	return sh;
}

ScopedHandles openPartitionTable(string fileName, OpenMode mode)
{
	assert(mode != OpenMode.Create);
	auto sh = openFileStream(fileName, mode);
	sh.table = XePartitionTable.tryOpen(sh.stream);
	return sh;
}

ScopedHandles openPartition(string fileName, uint part, OpenMode mode)
{
	auto sh = openPartitionTable(fileName, mode);
	if (sh.table)
	{
		uint p = 1;
		auto r = sh.table[];
		while (p < part && !r.empty) { ++p; r.popFront(); }
		if (p == part && !r.empty)
			sh.disk = r.front;
		else
			throw new Exception("Must specify a valid partition number");
	}
	else
	{
		enforce(!part, "Disk image does not contain a valid partition table");
		sh.disk = XeDisk.open(sh.stream, mode == OpenMode.ReadOnly
			? XeDiskOpenMode.ReadOnly : XeDiskOpenMode.ReadWrite);
	}
	return sh;
}

// xedisk create [-b bps] [-s nsec] [-d dtype] [-f fstype] image
void create(string[] args)
{
	uint sectors = 720;
	uint sectorSize = 256;
	string diskType = "ATR";
	string fsType;

	getopt(args,
		config.caseSensitive,
		"b|sector-size", &sectorSize,
		"s|sectors", &sectors,
		"d|disk-type", &diskType,
		"f|fs-type", &fsType);

	enforce(args.length >= 3, "Missing image file name");
	auto sh = createDisk(args[2], diskType, sectors, sectorSize);
	if (fsType.length)
		sh.fs = XeFileSystem.create(sh.disk, fsType);
}

unittest
{
	mixin(Test!"create (1)");
	enum disk = "testfiles/ut.atr";
	auto res = captureConsole(create(["", "", "-x", disk]));
	assert (res[0] == "");
	assert (res[1] == "");
	assert (res[2]);

	res = captureConsole(create(["", "", "-b", "256"]));
	assert (res[0] == "");
	assert (res[1] == "");
	assert (res[2]);
}

// xedisk mkfs [-p partition] -f fstype image
void mkfs(string[] args)
{
	uint partition;
	string fsType;

	getopt(args,
		config.caseSensitive,
		"p|partition", &partition,
		"f|fs-type", &fsType);

	enforce(args.length >= 3, "Missing image file name");
	enforce(fsType.length, "File system type not specified");
	auto sh = openPartition(args[2], partition, OpenMode.ReadWrite);
	sh.fs = XeFileSystem.create(sh.disk, fsType);
}

// xedisk info image ...
void info(string[] args)
{
	uint partition;
	bool oneline;

	getopt(args,
		config.caseSensitive,
		"s|oneline", &oneline,
		"p|partition", &partition);

	enforce(args.length >= 3, "Missing image file name.");
	foreach (file; args[2 .. $])
	{
		try
		{
			auto sh = partition
				? openPartition(file, partition, OpenMode.ReadOnly)
				: openPartitionTable(file, OpenMode.ReadOnly);

			if (oneline)
				writef("%-32.32s%8d ", sh.file.name.baseName(), sh.file.size);
			if (sh.table && !sh.disk)
			{
				writefln(oneline ? "%-16.16s %2d" :
					"Partition table type: %s\n" ~
					"Number of partitions: %s",
					sh.table.type, walkLength(sh.table[]));
				continue;
			}

			if (!sh.table && !sh.disk)
				sh.disk = XeDisk.tryOpen(sh.stream, XeDiskOpenMode.ReadOnly);

			if (!sh.disk && oneline)
				writeln("(unrecognized)");
			if (sh.disk)
			{
				writef(oneline ? "%-16.16s    %8d%4d " :
					"Disk type:            %s\n" ~
					"Total sectors:        %s\n" ~
					"Bytes per sectors:    %s\n",
					sh.disk.type, sh.disk.sectorCount,
					sh.disk.sectorSize);

				// TODO: s/open/tryOpen/g
				try
				{
					sh.fs = XeFileSystem.open(sh.disk);
					writef(oneline ? "%-16.16s %-11.11s%8d%12d\n" :
						"\nFile system type:     %s\n" ~
						"Label:                %s\n" ~
						"Free sectors:         %s\n" ~
						"Free bytes:           %s\n",
						sh.fs.getType(), sh.fs.getLabel(),
						sh.fs.getFreeSectors(), sh.fs.getFreeBytes());
				}
				catch (Exception e)
				{
					if (oneline)
						writeln("(unrecognized)");
				}
			}
		}
		catch (Exception e)
		{
			stderr.writefln("%s: `%s': %s",
				args[0], file, e.msg);
		}
	}
}

unittest
{
	mixin(Test!"info (1)");
	enum disk = "testfiles/ut.atr";
	auto res = captureConsole(info(["", ""]));
	assert (res[0] == "");
	assert (res[1] == "");
	assert (res[2]);
}

unittest
{
	mixin(Test!"create & info (1)");
	enum disk = "testfiles/ut.atr";
	scope (exit) if (exists(disk)) std.file.remove(disk);
	if (exists(disk)) std.file.remove(disk);
	auto res = captureConsole(create(["", "", disk]));
	assert (res[0] == "");
	assert (res[1] == "");
	assert (!res[2]);
	res = captureConsole(info(["", "", disk]));
	assert (res[0] ==
		"Disk type:            ATR\n" ~
		"Total sectors:        720\n" ~
		"Bytes per sectors:    256\n");
	assert (res[1] == "");
	assert (!res[2]);
}

unittest
{
	mixin(Test!"create & info (2)");
	enum disk = "testfiles/ut.xfd";
	scope (exit) if (exists(disk)) std.file.remove(disk);
	if (exists(disk)) std.file.remove(disk);
	auto res = captureConsole(create(["", "",
		"-b", "128",
		"-s", "1040", disk,
		"-f", "mydos",
		"-d", "xfd"
	]));
	assert (res[0] == "");
	assert (res[1] == "");
	assert (!res[2]);
	res = captureConsole(info(["", "", disk]));
	assert (res[0] ==
		"Disk type:            XFD\n" ~
		"Total sectors:        1040\n" ~
		"Bytes per sectors:    128\n\n" ~
		"File system type:     MyDOS\n" ~
		"Label:                \n" ~
		"Free sectors:         " ~ to!string(1040 - 3 - 2 - 8) ~ "\n" ~
		"Free bytes:           " ~ to!string((1040 - 3 - 2 - 8) * 125) ~ "\n");
	assert (res[1] == "");
}

// xedisk list image [-l [-s]] [path]
void list(string[] args)
{
	bool longFormat;
	bool sizeInSectors;
	uint partition;

	getopt(args,
		config.caseSensitive,
		config.bundling,
		"p|partition", &partition,
		"s|sectors", &sizeInSectors,
		"l|long", &longFormat);

	enforce(args.length >= 3, "Missing image file name");

	auto sh = openPartition(args[2], partition, OpenMode.ReadOnly);
	sh.fs = XeFileSystem.open(sh.disk);

	size_t nfiles;
	ulong totalSize;
	string path = args.length > 3 ? args[3] : "/";
	string mask = args.length > 4 ? args[4] : "*";
	foreach (entry; sh.fs.listDirectory(path, mask))
	{
		if (longFormat)
		{
			ulong size = sizeInSectors ? entry.getSectors() : entry.getSize();
			writefln("%s%s%s%s %10s %s %s",
				entry.isDirectory() ? "d" : "-",
				entry.isReadOnly() ? "r" : "-",
				entry.isHidden() ? "h" : "-",
				entry.isArchive() ? "a" : "-",
				size,
				entry.getTimeStamp(),
				entry.getName());
			++nfiles;
			totalSize += size;
		}
		else
			writeln(entry.getName());
	}

	if (longFormat)
	{
		writefln("%s files", nfiles);
		writefln("%s %s", totalSize, sizeInSectors ? "sectors" : "bytes");
		if (sizeInSectors)
			writefln("%s free sectors", sh.fs.getFreeSectors());
		else
			writefln("%s free bytes", sh.fs.getFreeBytes());
	}
}

unittest
{
	mixin(Test!"list (3)");
	enum disk = "testfiles/MYDOS450.ATR";
	auto res = captureConsole(list(["", "", disk]));
	assert (res[0] ==
		"dos.sys\ndup.sys\nramboot.m65\nramboot.aut\nramboot3.m65\n" ~
		"ramboot3.aut\nread.me\n");
	assert (res[1] == "");
	assert (!res[2]);

	res = captureConsole(list(["", "", "-l", disk]));
	assert (res[0] ==
`----       4375 0001-Jan-01 00:00:00 dos.sys
----       6638 0001-Jan-01 00:00:00 dup.sys
----       5452 0001-Jan-01 00:00:00 ramboot.m65
----        755 0001-Jan-01 00:00:00 ramboot.aut
----       7111 0001-Jan-01 00:00:00 ramboot3.m65
----       1156 0001-Jan-01 00:00:00 ramboot3.aut
----        230 0001-Jan-01 00:00:00 read.me
7 files
25717 bytes
62375 free bytes
`);
	assert (res[1] == "");
	assert (!res[2]);

	res = captureConsole(list(["", "", "-ls", disk]));
	assert (res[0] ==
`----         35 0001-Jan-01 00:00:00 dos.sys
----         54 0001-Jan-01 00:00:00 dup.sys
----         44 0001-Jan-01 00:00:00 ramboot.m65
----          7 0001-Jan-01 00:00:00 ramboot.aut
----         57 0001-Jan-01 00:00:00 ramboot3.m65
----         10 0001-Jan-01 00:00:00 ramboot3.aut
----          2 0001-Jan-01 00:00:00 read.me
7 files
209 sectors
499 free sectors
`);
	assert (res[1] == "");
	assert (!res[2]);
}

// xedisk add image [-d=dest_dir] [-r] src_files ...
void add(string[] args)
{
	string destDir = "/";
	bool forceOverwrite;
	bool interactive;
	bool autoRename;
	bool recursive;
	bool verbose;

	getopt(args,
		config.caseSensitive,
		config.bundling,
		"d|dest-dir", &destDir,
		"f|force", &forceOverwrite,
		"i|interactive", &interactive,
		"n|auto-rename", &autoRename,
		"r|recursive", &recursive,
		"v|verbose", &verbose);

	enforce(args.length >= 4, format(
		"Missing arguments. Try `%s help add'.", args[0]));

	auto stream = new FileStream(File(args[2], "r+b"));
	scope(exit) destroy(stream);
	auto disk = XeDisk.open(stream, XeDiskOpenMode.ReadWrite);
	scope(exit) destroy(disk);
	auto fs = XeFileSystem.open(disk);
	scope(exit) destroy(fs);
	auto dir = enforce(
		cast(XeDirectory) fs.getRootDirectory().find(destDir),
		format("`%s' is not a directory", destDir));
	scope(exit) destroy(dir);

	string makeSureNameIsValid(string name)
	{
		if (fs.isValidName(name))
			return name;
		if (autoRename)
			return fs.adjustName(name);
		else if (interactive)
		{
			do
			{
				writefln("Name `%s' is invalid in %s file system, input a valid name:",
					name, fs.getType());
				name = chomp(readln());
				if (!name.length)
					return null;
			}
			while (!fs.isValidName(name));
			return name;
		}
		throw new Exception(format("Invalid file name `%s'", name));
	}

	enum ReadAndParseUserChoice =
	q{
		auto ans = chomp(readln());
		if (ans == "d") { existing.remove(true); break; }
		else if (ans == "n")
		{
			writefln("New name:");
			bn = makeSureNameIsValid(chomp(readln()));
			if (!bn.length)
				continue;
			break;
		}
		else if (ans == "s") { return; }
	};

	void copyFile(string name, XeDirectory dest)
	{
		string bn = makeSureNameIsValid(name.baseName());
		if (verbose)
			writefln("`%s' -> `%s/%s'", name, dest.getFullPath(), bn);
		XeEntry existing;
		while ((existing = dest.find(bn)) !is null)
		{
			if (interactive)
			{
				for (;;)
				{
					writeln(existing, " already exists. Delete/reName/Skip?");
					mixin (ReadAndParseUserChoice);
				}
			}
			else if (forceOverwrite)
				existing.remove(true);
			else
				throw new Exception(text(
					existing, " already exists. Use `-f' to force overwrite."));
		}
		scope file = dest.createFile(bn);
		foreach (ubyte[] buf; File(name).byChunk(16384))
			file.write(buf);
	}

	void copyDirectory(string name, XeDirectory dest)
	{
		string bn = makeSureNameIsValid(name.baseName());
		if (verbose)
			writefln("`%s' -> `%s/%s'", name, dest.getFullPath(), bn);
		XeEntry existing;
		while ((existing = dest.find(bn)) !is null)
		{
			if (interactive)
			{
				for (;;)
				{
					writefln("%s already exists. %sDelete/reName/Skip?",
						existing, existing.isDirectory() ? "Keep/" : "");
					mixin (ReadAndParseUserChoice);
					if (ans == "k" && existing.isDirectory())
						goto doIt;
				}
			}
			else if (forceOverwrite)
			{
				if (existing.isDirectory())
					break; // re-use
				existing.remove(true);
			}
			else
				throw new Exception(text(
					existing, " already exists. Use `-f' to force overwrite."));
		}
doIt:
		auto newDir = (existing && existing.isDirectory()) ?
			cast(XeDirectory) existing : dest.createDirectory(bn);
		foreach (DirEntry e; dirEntries(name, SpanMode.shallow))
		{
			if (e.isDir)
				copyDirectory(e.name, newDir);
			if (e.isFile)
				copyFile(e.name, newDir);
		}
	}

	foreach (f; args[3 .. $])
	{
		if (f.isDir)
		{
			if (!recursive)
				throw new Exception(
					format("`%s' is a directory. Forgot the `-r' switch?", f));
			copyDirectory(buildNormalizedPath(getcwd(), f), dir);
		}
		else if (f.isFile)
			copyFile(f, dir);
		else
			throw new Exception(format("Don't know how to copy `%s'", f));
	}
}

unittest
{
	mixin(Test!"add (1)");
	enum disk = "testfiles/ut.atr";
	enum emptyfile = "testfiles/empty_files/DOS25.XFD";
	enum bigfile = "testfiles/DOS25.XFD";
	enum bigfile_bn = "DOS25.XFD";

	scope (exit) if (exists(disk)) std.file.remove(disk);
	if (exists(disk)) std.file.remove(disk);
	auto res = captureConsole(create(["", "", disk, "-f", "mydos"]));
	assert (res[0] == "");
	assert (res[1] == "");
	assert (!res[2]);

	res = captureConsole(add(["", "", disk]));
	assert (res[2]); // no files to add
	res = captureConsole(add(["", "", disk, "testfiles/dir"]));
	assert (res[2]); // can't add dir without "-r"
	res = captureConsole(add(["", "", disk, bigfile]));
	assert (!res[2]);
	res = captureConsole(add(["", "", disk, "-r", "testfiles/dir"]));
	assert (!res[2]);
	res = captureConsole(add(["", "", disk, bigfile]));
	assert (res[2]); // can't overwrite
	res = captureConsole(add(["", "", disk, "-f", bigfile]));
	assert (!res[2]); // "-f" allows overwrite

	assert (getSize(emptyfile) == 0); // just to be sure
	res = captureConsole(add(["", "", disk, "-i", emptyfile]), "s\n");
	assert (!res[2]); // interactive, answers "skip"
	assert (findOnDisk(disk, bigfile_bn).getSize() == getSize(bigfile));

	res = captureConsole(add(["", "", disk, "-i", emptyfile]),
		"n\nemptyfile\nemptyfil.e\n"); // try with bad name first ;)
	assert (!res[2]); // interactive, answers "rename"
	assert (findOnDisk(disk, bigfile_bn).getSize() == getSize(bigfile));
	assert (findOnDisk(disk, "emptyfil.e").getSize() == 0);

	res = captureConsole(add(["", "", disk, "-i", emptyfile]), "d\n");
	assert (!res[2]); // interactive, answers "overwrite"
	assert (findOnDisk(disk, bigfile_bn).getSize() == 0);
}

// xedisk extract image [files...]
// (if no files given, extract everything)
void extract(string[] args)
{
	string destDir = ".";
	bool verbose;
	uint partition;

	getopt(args,
		config.caseSensitive,
		config.bundling,
		"d|dest-dir", &destDir,
		"v|verbose", &verbose,
		"p|partition", &partition);

	enforce(args.length >= 3, format(
		"Missing arguments. Try `%s help extract'.", args[0]));
	if (args.length == 3)
		args ~= "/";

	if (!exists(destDir))
		mkdir(destDir);
	else
		enforce(isDir(destDir), format("`%s' is not a directory", destDir));

	auto sh = openPartition(args[2], partition, OpenMode.ReadOnly);
	sh.fs = XeFileSystem.open(sh.disk);

	void copyFile(XeEntry entry, string destName)
	{
		auto fstream = (cast(XeFile) entry).openReadOnly();
		auto buf = new ubyte[16384];
		auto ofile = File(destName, "wb");
		while (0 < (buf.length = fstream.read(buf)))
			ofile.rawWrite(buf);
	}

	string buildDestName(XeEntry entry)
	{
		auto destName = buildNormalizedPath(destDir ~ entry.getFullPath());
		if (verbose && entry.getParent())
			writefln("`%s%s' -> `%s'", args[2], entry.getFullPath(), destName);
		return destName;
	}

	foreach (name; args[3 .. $])
	{
		auto top = sh.fs.getRootDirectory().find(name);
		auto destName = buildDestName(top);
		if (top.isDirectory())
		{
			foreach (entry; (cast(XeDirectory) top).enumerate(XeSpanMode.Breadth))
			{
				destName = buildDestName(entry);
				if (entry.isDirectory())
					mkdirRecurse(destName);
				else if (entry.isFile())
					copyFile(entry, destName);
			}
		}
		else if (top.isFile())
			copyFile(top, destName);
	}
}

void createDir(string[] args)
{
	uint partition;

	getopt(args,
		config.caseSensitive,
		"p|partition", &partition);

	enforce(args.length >= 4, "Missing directory name");

	auto sh = openPartition(args[2], partition, OpenMode.ReadWrite);
	sh.fs = XeFileSystem.open(sh.disk);
	sh.fs.getRootDirectory().createDirectory(args[3]);
}

// xedisk dump image [sector_range]
void dump(string[] args)
{
	uint partition;

	getopt(args,
		config.caseSensitive,
		"p|partition", &partition);

	enforce(args.length >= 3, "Missing image file name");
	auto outfile = stdout;
	auto sh = openPartition(args[2], partition, OpenMode.ReadOnly);
	auto buf = new ubyte[sh.disk.sectorSize];
	if (args.length == 3)
		args ~= "-";
	foreach (arg; args[3 .. $])
	{
		foreach (sector; parseSectorRange(arg, sh.disk.sectorCount))
		{
			auto n = sh.disk.readSector(sector, buf);
			outfile.rawWrite(buf[0 .. n]);
		}
	}
}

// xedisk cat image file...
void cat(string[] args)
{
	uint partition;

	getopt(args,
		config.caseSensitive,
		"p|partition", &partition);

	enforce(args.length >= 3, "Missing image file name");
	enforce(args.length >= 4, "Missing file name");

	auto sh = openPartition(args[2], partition, OpenMode.ReadOnly);
	sh.fs = XeFileSystem.open(sh.disk);
	auto buf = new ubyte[4096];
	foreach (fn; args[3 .. $])
	{
		auto fstream =
			enforce(cast(XeFile)
				enforce(sh.fs.getRootDirectory().find(fn),
					format("File not found: `%s'", fn)),
				format("`%s' is not a regular file", fn)).openReadOnly();
		size_t s;
		while ((s = fstream.read(buf)) > 0)
			stdout.rawWrite(buf[0 .. s]);
	}
}

void writeDos(string[] args)
{
	string dosVersion;

	getopt(args,
		config.caseSensitive,
		"D|dos-version", &dosVersion);

	enforce(args.length >= 3, format(
		"Missing arguments. Try `%s help write-dos'.", args[0]));

	auto stream = new FileStream(File(args[2], "r+b"));
	scope(exit) destroy(stream);
	auto disk = XeDisk.open(stream, XeDiskOpenMode.ReadWrite);
	scope(exit) destroy(disk);
	auto fs = XeFileSystem.open(disk);
	scope(exit) destroy(fs);
	fs.writeDosFiles(dosVersion);
}

void listPartitions(string[] args)
{
	auto sh = openPartitionTable(args[2], OpenMode.ReadOnly);
	enforce(sh.table, "The image does not contain a valid partition table");
	uint i;
	writefln("%3s  %10s %10s %10s  %10s %4s  %s", "#", "Ph.Start", "Ph.End",
		"Ph.Sectors", "Sectors", "BPS", "Type");
	foreach (partition; sh.table)
	{
		writefln("%3d. %10d %10d %10d  %10d %4d  %s",
			++i, partition.firstPhysicalSector,
			partition.firstPhysicalSector + partition.sectorCount - 1,
			partition.physicalSectorCount,
			partition.sectorCount, partition.sectorSize,
			partition.type);
	}
}

void diskCopy(string[] args)
{
	uint inputPartition;
	uint outputPartition;
	string outputType;

	getopt(args,
		config.caseSensitive,
		"p|input-partition", &inputPartition,
		"P|output-partition", &outputPartition,
		"t|output-type", &outputType);

	enforce(args.length >= 4, format(
		"Missing arguments. Try `%s help %s'.", args[0], args[1]));

	auto src = openPartition(args[2], inputPartition, OpenMode.ReadOnly);
	auto dest = exists(args[3])
		? openPartition(args[3], outputPartition, OpenMode.ReadWrite)
		: createDisk(args[3],
			outputType.length ? outputType : src.disk.type,
			src.disk.sectorCount, src.disk.sectorSize);
	enforce(src.disk.sectorCount == dest.disk.sectorCount
		&& src.disk.sectorSize == dest.disk.sectorSize,
		"Output disk geometry is different than the input disk geometry");
	auto buf = new ubyte[src.disk.sectorSize];
	foreach (sector; 1 .. src.disk.sectorCount + 1)
		dest.disk.writeSector(sector,
			buf[0 .. src.disk.readSector(sector, buf)]);
}

void printHelp(string[] args)
{
	writeln("no help yet");
}

int xedisk_main(string[] args)
{
	if (args.length > 1)
	{
		immutable funcs = [
			"create":&create,
			"n":&create,
			"mkfs":&mkfs,
			"info":&info,
			"i":&info,
			"list":&list,
			"ls":&list,
			"l":&list,
			"dir":&list,
			"add":&add,
			"a":&add,
			"extract":&extract,
			"x":&extract,
			"mkdir":&createDir,
			"md":&createDir,
			"dump":&dump,
			"cat":&cat,
			"write-dos":&writeDos,
			"list-partitions":&listPartitions,
			"lp":&listPartitions,
			"dc":&diskCopy,
			"help":&printHelp,
			"-h":&printHelp,
			"--help":&printHelp
			];
		auto fun = funcs.get(args[1], null);
		if (fun !is null) {
			fun(args);
			return 0;
		}
	}
	throw new XeException(format("Missing command. Try `%s help'", args[0]));
}

version(unittest) {} else
{
	int main(string[] args)
	{
		debug
		{
			return xedisk_main(args);
		}
		else
		{
			try
			{
				return xedisk_main(args);
			}
			catch (XeException e)
			{
				stderr.writefln("%s: %s", args[0], e);
				return 1;
			}
			catch (Exception e)
			{
				stderr.writefln("%s: %s", args[0], e.msg);
				return 1;
			}
		}
	}
}

/+
unittest
{
	auto res = captureConsole(main(["xedisk"]));
	assert (res[0] == "");
	assert (res[1] == "Missing command. Try `xedisk help'\n");
	assert (!res[2]);
}+/
