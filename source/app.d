import bindbc.glfw;
import bindbc.opengl;
import std.stdio;
import window;

static class App
{
	private static Window[] windows;
	private static bool isRunning = false;

	static void initialize()
	{
		// Load GLFW
		GLFWSupport retVal = loadGLFW();
		if (retVal != glfwSupport)
		{
			if (retVal == GLFWSupport.noLibrary)
			{
				writeln("Error: GLFW library not found!");
				throw new Exception("GLFW library not found");
			}
			else if (retVal == GLFWSupport.badLibrary)
			{
				writeln("Error: GLFW library is broken!");
				throw new Exception("GLFW library is broken");
			}
		}

		// Initialize GLFW
		if (!glfwInit())
		{
			writeln("Error: Failed to initialize GLFW");
			throw new Exception("Failed to initialize GLFW");
		}

		isRunning = true;
	}

	static Window createWindow(int width, int height, string title)
	{
		auto window = new Window()
			.setWidth(width)
			.setHeight(height)
			.setTitle(title)
			.Create();
		windows ~= window;
		return window;
	}

	static void update(double deltaTime)
	{
		foreach (window; windows)
		{
			if (window.isOpen())
			{
				window.update(deltaTime);
			}
		}
	}

	static void render()
	{
		foreach (window; windows)
		{
			if (window.isOpen())
			{
				window.render();
			}
		}
	}

	static bool shouldRun()
	{
		return isRunning && windows.length > 0;
	}

	static void shutdown()
	{
		isRunning = false;
		foreach (window; windows)
		{
			window.destroy();
		}
		windows = [];
		glfwTerminate();
	}
}
