import app;
import window;
import utils;
import std.stdio;

int main()
{
	writeln();

	try
	{
		App.initialize();
		App.windows ~= new Window()
			.setWidth(800)
			.setHeight(600)
			.setTitle("Ravtech")
			.Create();

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

