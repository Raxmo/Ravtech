import bindbc.glfw;
import bindbc.opengl;
import std.stdio;

class App
{
	GLFWwindow* window; // <-- will be changed to a window manager at some point

	this()
	{
		// Initialize app
	}
	
	void initialize()
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

		// Create a windowed mode window and its OpenGL context
		window = glfwCreateWindow(800, 600, "Ravtech", null, null);
		if (!window)
		{
			writeln("Error: Failed to create GLFW window");
			glfwTerminate();
			throw new Exception("Failed to create GLFW window");
		}

		// Make the window's context current
		glfwMakeContextCurrent(window);

		// Load OpenGL
		GLSupport retVal2 = loadOpenGL();
		if (retVal2 == GLSupport.noLibrary)
		{
			writeln("Error: OpenGL library not found!");
			throw new Exception("OpenGL library not found");
		}
		else if (retVal2 == GLSupport.badLibrary)
		{
			writeln("Error: OpenGL library is broken!");
			throw new Exception("OpenGL library is broken");
		}

		glClearColor(0.75f, 0.4f, 0.2f, 1.0f);


		writeln("Window created successfully");
	}

	void update(double deltaTime)
	{
		// Update game state
	}

	void render()
	{
		glClear(GL_COLOR_BUFFER_BIT);
		// Render frame
		glfwSwapBuffers(window);
	}

	bool shouldRun()
	{
		return !glfwWindowShouldClose(window);
	}

	void handleInput()
	{
		glfwPollEvents();
	}

	void shutdown()
	{
		// Cleanup
		if (window)
		{
			glfwDestroyWindow(window);
		}
		glfwTerminate();
	}
}
