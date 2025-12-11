import app;
import std.stdio;

int main()
{
	App app = new App();

	try
	{
		app.initialize();

		while (app.shouldRun())
		{
			app.handleInput();
			app.update(0.016);  // ~60 FPS deltaTime
			app.render();
		}

		app.shutdown();
	}
	catch (Exception e)
	{
		writeln("Error: ", e.msg);
		return 1;
	}

	return 0;
}

