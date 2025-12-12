import std.stdio;

class Logger
{
	enum Mode { Console, File, Both }
	
	private Mode mode = Mode.Console;
	private File outputFile;
	
	Logger console()
	{
		mode = Mode.Console;
		return this;
	}
	
	Logger file(string filename)
	{
		mode = Mode.File;
		if (outputFile.isOpen()) outputFile.close();
		outputFile = File(filename, "a");
		return this;
	}
	
	Logger both(string filename)
	{
		mode = Mode.Both;
		if (outputFile.isOpen()) outputFile.close();
		outputFile = File(filename, "a");
		return this;
	}
	
	Logger info(string msg)
	{
		writeLog("INFO", msg);
		return this;
	}
	
	Logger warn(string msg)
	{
		writeLog("WARN", msg);
		return this;
	}
	
	Logger error(string msg)
	{
		writeLog("ERROR", msg);
		return this;
	}
	
	private void writeLog(string prefix, string msg)
	{
		string formatted = "[" ~ prefix ~ "] " ~ msg;
		final switch(mode) {
			case Mode.Console:
				writeln(formatted);
				break;
			case Mode.File:
				outputFile.writeln(formatted);
				break;
			case Mode.Both:
				writeln(formatted);
				outputFile.writeln(formatted);
				break;
		}
	}
}
