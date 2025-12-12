import bindbc.glfw;
import bindbc.opengl;
import std.stdio;

class Window
{
	private GLFWwindow* handle;
	private int width = 800;
	private int height = 600;
	private string title = "Window";

	this()
	{
		// Builder pattern - configure before Present()
	}

	Window setWidth(int w)
	{
		width = w;
		return this;
	}

	Window setHeight(int h)
	{
		height = h;
		return this;
	}

	Window setTitle(string t)
	{
		title = t;
		return this;
	}

	Window Create()
	{
		if (handle != null)
			throw new Exception("Window already created");

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
		return this;
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

	@property GLFWwindow* Handle()
	{
		return handle;
	}
}
