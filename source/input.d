import bindbc.glfw;
import core.thread;
import core.atomic;
import core.time;
import std.stdio;
import event;

class InputThread
{
	private Thread thread;
	private shared bool isRunning = false;
	private GLFWwindow* window;
	private ThreadSafeInputQueue inputQueue;

	this(GLFWwindow* window, ThreadSafeInputQueue inputQueue)
	{
		this.window = window;
		this.inputQueue = inputQueue;
	}

	void start()
	{
		atomicStore(isRunning, true);
		thread = new Thread(&run);
		thread.start();
		writeln("Input thread started");
	}

	void stop()
	{
		atomicStore(isRunning, false);
		if (thread)
		{
			thread.join();
		}
		writeln("Input thread stopped");
	}

	private void run()
	{
		while (atomicLoad(isRunning))
		{
			// Poll GLFW for events (fires callbacks)
			glfwPollEvents();
			
			// Sleep briefly to prevent CPU spin
			Thread.sleep(dur!("msecs")(1));
		}
	}

	void setupCallbacks()
	{
		// Key input callback
		auto keyCallback = (GLFWwindow* w, int key, int scancode, int action, int mods) {
			long timestamp = MonoTime.currTime().ticks();
			this.inputQueue.push(() {
				// Handle key input (placeholder)
				// writeln("Key: ", key, " Action: ", action);
			}, timestamp);
		};
		glfwSetKeyCallback(window, cast(GLFWkeyfun)keyCallback);

		// Mouse button callback
		auto mouseCallback = (GLFWwindow* w, int button, int action, int mods) {
			long timestamp = MonoTime.currTime().ticks();
			this.inputQueue.push(() {
				// Handle mouse input (placeholder)
				// writeln("Mouse button: ", button, " Action: ", action);
			}, timestamp);
		};
		glfwSetMouseButtonCallback(window, cast(GLFWmousebuttonfun)mouseCallback);

		// Window close callback
		auto closeCallback = (GLFWwindow* w) {
			// Set shutdown flag (to be handled by main thread)
			// For now, just stop polling
			atomicStore(this.isRunning, false);
		};
		glfwSetWindowCloseCallback(window, cast(GLFWwindowclosefun)closeCallback);
	}
}
