import bindbc.glfw;
import core.thread;
import core.sync.mutex;
import core.sync.condition;
import core.atomic;
import core.time;
import std.stdio;

// Input action enum
enum Action
{
	None = 0
}

static class Input
{
	static struct MouseState
	{
		double x;
		double y;
	}

	private static GLFWwindow* window;
	private static MouseState mouse;
	private static Mutex mouseMutex;

	static this()
	{
		mouseMutex = new Mutex();
	}

	static void initialize(GLFWwindow* win)
	{
		window = win;
		updateMousePosition();
	}

	static MouseState Mouse()
	{
		synchronized (mouseMutex)
		{
			return mouse;
		}
	}

	static void updateMousePosition()
	{
		if (!window)
			return;

		double x, y;
		glfwGetCursorPos(window, &x, &y);

		synchronized (mouseMutex)
		{
			mouse.x = x;
			mouse.y = y;
		}
	}
}
