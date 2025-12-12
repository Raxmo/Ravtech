import app;
import utils;
import std.stdio;

int main()
{
	writeln();

	try
	{
		App.initialize();
		App.createWindow(800, 600, "Ravtech");

		while (App.shouldRun())
		{
			App.update(0.016);  // ~60 FPS deltaTime
			App.render();
		}

		App.shutdown();
	}
	catch (Exception e)
	{
		writeln("Error: ", e.msg);
		return 1;
	}

	return 0;
}

