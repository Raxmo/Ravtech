import bindbc.glfw;
import app;
import core.sync.mutex;
import core.sync.condition;
import core.time;

struct MousePosition
{
	double x;
	double y;
}

struct Action
{
	immutable long id = 0;
	
	this(int dummy = 0)
	{
		static long nextId = 0;
		id = ++nextId;
	}
}

struct BindingContext
{
	immutable long id = 0;
	
	this(int dummy = 0)
	{
		static long nextId = 0;
		id = ++nextId;
	}
}

private struct QueuedAction
{
	Action action;
	long timestamp;
}

private struct ActionQueue
{
	QueuedAction[] writeBuffer;
	QueuedAction[] readBuffer;
	Mutex lock;
	Condition condition;
	
	void initialize()
	{
		lock = new Mutex();
		condition = new Condition(lock);
		writeBuffer = [];
		readBuffer = [];
	}
	
	void pushAction(Action action)
	{
		synchronized (lock)
		{
			QueuedAction qa;
			qa.action = action;
			qa.timestamp = MonoTime.currTime().ticks();
			writeBuffer ~= qa;
			condition.notify();
		}
	}
	
	QueuedAction[] pollActions()
	{
		synchronized (lock)
		{
			auto temp = readBuffer;
			readBuffer = writeBuffer;
			writeBuffer = [];
			return temp;
		}
	}
	
	QueuedAction[] waitForActions(Duration timeout = Duration.max)
	{
		synchronized (lock)
		{
			while (writeBuffer.length == 0)
			{
				if (timeout == Duration.max)
					condition.wait();
				else
					condition.wait(timeout);
			}
			return pollActions();
		}
	}
}

static class Input
{
	// Internal: Bindings organized by context
	// bindings[contextId] = Action[inputId]
	private static Action[int][long] bindings;
	private static BindingContext currentContext = BindingContext(0);
	
	// Input action queue (double-buffered)
	private static ActionQueue actionQueue;
	
	static this()
	{
		actionQueue.initialize();
	}
	
	static class Mouse
	{
		@property static MousePosition position()
		{
			// Get cursor position from currently focused window
			GLFWwindow* focusedWindow = App.getFocusedWindow();
			if (!focusedWindow)
				return MousePosition(0, 0);
			
			double x, y;
			glfwGetCursorPos(focusedWindow, &x, &y);
			return MousePosition(x, y);
		}
	}
	
	// Public API: Create a new binding context
	static BindingContext createContext()
	{
		BindingContext context = BindingContext();
		bindings[context.id] = (Action[int]).init;
		return context;
	}
	
	// Public API: Switch to a binding context
	static void setContext(BindingContext context)
	{
		if (context.id in bindings)
			currentContext = context;
	}
	
	// Public API: Get keys bound to an action in current context
	static int[] getKeysForAction(Action action)
	{
		int[] keys;
		if (currentContext.id in bindings)
		{
			foreach (key, boundAction; bindings[currentContext.id])
			{
				if (boundAction.id == action.id)
					keys ~= key;
			}
		}
		return keys;
	}
	
	// Public API: Bind a key to an action in current context
	static void bind(int key, Action action)
	{
		if (currentContext.id in bindings)
			bindings[currentContext.id][key] = action;
	}
	
	// Public API: Unbind a key in current context
	static void unbind(int key)
	{
		if (currentContext.id in bindings)
			bindings[currentContext.id].remove(key);
	}
	
	// Get action for a key in current context
	static Action getActionForKey(int key)
	{
		if (currentContext.id in bindings && key in bindings[currentContext.id])
			return bindings[currentContext.id][key];
		return Action(0);
	}
	
	// Queue an action (called by input thread or callbacks)
	static void queueAction(Action action)
	{
		actionQueue.pushAction(action);
	}
	
	// Poll queued actions (non-blocking, main thread)
	static QueuedAction[] pollActions()
	{
		return actionQueue.pollActions();
	}
	
	// Wait for actions (blocking with optional timeout, main thread)
	static QueuedAction[] waitForActions(Duration timeout = Duration.max)
	{
		return actionQueue.waitForActions(timeout);
	}
}
