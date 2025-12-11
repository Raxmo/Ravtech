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
/*

dt = getDt();

const pdt = 6000ns;
pct = 0ns;

fixedPhysics(dt)
{
	while((pct += pdt) < dt)
	{
		physics(pdt);
	}
	pct -= dt
}

DoRender();





	*/
