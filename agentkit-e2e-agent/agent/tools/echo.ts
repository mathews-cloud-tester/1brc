import { defineTool } from "@cursor/july/tools";
import { z } from "zod";

export default defineTool({
  description: "Echo a short message back (demo tool).",
  inputSchema: z.object({ message: z.string() }),
  async execute({ message }) {
    return { echoed: message };
  },
});
