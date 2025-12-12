import bindbc.glfw;
import bindbc.opengl;
import std.stdio;

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
		auto window = new Window(width, height, title);
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

class Window
{
	private GLFWwindow* handle;
	private int width;
	private int height;
	private string title;

	this(int w, int h, string t)
	{
		width = w;
		height = h;
		title = t;

		handle = glfwCreateWindow(width, height, title.ptr, null, null);
		if (!handle)
		{
			throw new Exception("Failed to create GLFW window");
		}

		glfwMakeContextCurrent(handle);

		// Load OpenGL
		GLSupport retVal = loadOpenGL();
		if (retVal == GLSupport.noLibrary)
		{
			throw new Exception("OpenGL library not found");
		}
		else if (retVal == GLSupport.badLibrary)
		{
			throw new Exception("OpenGL library is broken");
		}

		glClearColor(0.75f, 0.4f, 0.2f, 1.0f);
		writeln("Window created: ", title);
	}

	void update(double deltaTime)
	{
		glfwPollEvents();
	}

	void render()
	{
		glfwMakeContextCurrent(handle);
		glClear(GL_COLOR_BUFFER_BIT);
		glfwSwapBuffers(handle);
	}

	bool isOpen()
	{
		return !glfwWindowShouldClose(handle);
	}

	void destroy()
	{
		if (handle)
		{
			glfwDestroyWindow(handle);
			handle = null;
		}
	}

	GLFWwindow* getHandle()
	{
		return handle;
	}
}
