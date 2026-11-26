// exact-rive on Android: not implemented yet. `rive-view` is an empty view that says so with
// `message="error:…"`, so the `Rive` component shows its still, as for a file that can't load. The
// implementation to come is Rive's Android runtime (app.rive:rive-android) behind the same props.
package exactrive

import android.content.Context
import android.view.View
import dev.exact.canvas.ExactExtension
import dev.exact.canvas.ExtensionContext
import org.json.JSONObject

class RiveModule(context: ExtensionContext) : ExactExtension(context) {
    override fun later(name: String, args: JSONObject, reply: (JSONObject) -> Unit) {
        reply(JSONObject().put("error", "NotSupportedError"))
    }

    override fun view(tag: String, session: String, id: String, context: Context, props: JSONObject, emit: (String, String) -> Unit): View {
        require(tag == "rive-view") { "no view $tag" }
        val box = View(context)
        box.post { emit("message", "error:exact-rive: Rive on Android is not implemented yet") }
        return box
    }

    override fun update(view: View, props: JSONObject) {}
}
