defmodule ExMujoco.Gen.Header do
  @moduledoc """
  Reads MuJoCo's C headers into data.

  MuJoCo generates its own Python bindings the same way — `python/mujoco/introspect`
  parses the headers and checks the result in. This is the same idea in Elixir: the
  headers are the source of truth, the catalogue is checked in beside us, and
  `mix ex_mujoco.gen --check` proves the two agree.

  Three things are read:

    * **functions** — every `MJAPI` declaration in `mujoco.h` and the headers it
      includes;
    * **structs** — the members of `mjModel` and `mjData`, with the dimensions of
      their arrays taken from `mjxmacro.h`, which exists to be read like this;
    * **enums** — every `typedef enum mjtX { … } mjtX;`.

  Nothing here decides what is *bound*; it only says what exists. `ExMujoco.Gen`
  holds that decision, in `c_src/manifest.exs`.
  """

  @callbacks ~w(mjfGeneric mjfConFilt mjfSensor mjfTime mjfAct mjfCollision)
  @numeric ~w(mjtNum float double)
  @integers ~w(int mjtSize size_t uintptr_t unsigned short long)

  @typedoc "A C type as it appears in a declaration: `mjtNum*`, `const char*`."
  @type ctype :: %{name: String.t(), const: boolean(), pointers: non_neg_integer()}

  @type parameter :: %{
          name: String.t(),
          type: ctype(),
          array: String.t() | nil,
          kind: :integer | :float | :string | :buffer | :resource | :opaque | :callback
        }

  @type function_decl :: %{
          name: String.t(),
          returns: ctype(),
          parameters: [parameter()],
          doc: String.t(),
          section: String.t() | nil,
          variadic: boolean()
        }

  @type member :: %{
          name: String.t(),
          type: ctype(),
          array: String.t() | nil,
          doc: String.t(),
          section: String.t() | nil
        }

  @type enum :: %{
          name: String.t(),
          items: [%{name: String.t(), value: integer() | nil, doc: String.t()}]
        }

  @doc """
  Everything the headers say, as one map.

  `dir` is a MuJoCo include root, the one `MUJOCO_DIR` names: it must hold
  `mujoco/mujoco.h`.
  """
  @spec read(Path.t()) :: %{
          functions: [function_decl()],
          structs: %{String.t() => [member()]},
          enums: [enum()],
          version: non_neg_integer() | nil
        }
  def read(dir) do
    headers = headers!(dir)

    %{
      functions: headers |> Enum.flat_map(&functions_in/1) |> Enum.uniq_by(& &1.name),
      structs:
        Map.new(~w(mjModel mjData), fn struct -> {struct, struct_members!(dir, struct)} end),
      enums: headers |> Enum.flat_map(&enums_in/1) |> Enum.uniq_by(& &1.name),
      version: header_version!(dir)
    }
  end

  defp headers!(dir) do
    main = Path.join(dir, "mujoco/mujoco.h")

    unless File.exists?(main) do
      raise """
      #{main} is not there.

      ExMujoco reads MuJoCo's headers to generate its bindings, so it needs a
      MuJoCo to read:

          elixir scripts/prepare_mujoco.exs --ensure

      puts one under `_build/mujoco/`, or point MUJOCO_DIR at an install.
      """
    end

    main
    |> File.read!()
    |> then(fn text ->
      text
      |> includes()
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(&File.exists?/1)
      |> then(&[main | &1])
    end)
  end

  defp includes(text) do
    ~r/^#include <(mujoco\/[A-Za-z0-9_]+\.h)>/m
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp header_version!(dir) do
    with {:ok, text} <- File.read(Path.join(dir, "mujoco/mujoco.h")),
         [_, number] <- Regex.run(~r/#define mjVERSION_HEADER (\d+)/, text) do
      String.to_integer(number)
    else
      _ -> nil
    end
  end

  # ------------------------------------------------------------------ functions

  @doc """
  The `MJAPI` declarations in one header.
  """
  @spec functions_in(Path.t()) :: [function_decl()]
  def functions_in(path) do
    text = File.read!(path)
    notes = annotations(text)

    text
    |> strip_comments()
    |> declarations()
    |> Enum.flat_map(&declaration!/1)
    |> Enum.map(&Map.merge(&1, Map.get(notes, &1.name, %{doc: "", section: nil})))
  end

  # What MuJoCo says above a declaration, which the C itself does not carry:
  # a prose comment per function, and `// ---- Forward dynamics ----` lines that
  # open a run of them. The declarations are read without the comments, so this
  # is a separate pass over the text, keyed by the name in the declaration.
  defp annotations(text) do
    {annotations, _pending} =
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reduce({%{}, %{section: nil, doc: []}}, &read_line/2)

    annotations
  end

  # One line at a time: a heading, a line of the description, the declaration the
  # description belongs to, or something else, which ends the description.
  defp read_line(line, {found, pending}) do
    cond do
      banner?(line) ->
        {found, %{pending | section: heading(String.replace_prefix(line, "//", ""))}}

      String.starts_with?(line, "//") ->
        {found, %{pending | doc: [comment(line) | pending.doc]}}

      String.contains?(line, "MJAPI") ->
        record(found, pending, declared_name(line))

      true ->
        {found, %{pending | doc: []}}
    end
  end

  # A global function pointer (`MJAPI extern void* (*mju_user_malloc)(size_t)`)
  # has no name to file it under, and is not a function the bindings can expose.
  defp record(found, pending, nil), do: {found, %{pending | doc: []}}

  defp record(found, pending, name),
    do: {Map.put(found, name, note(pending)), %{pending | doc: []}}

  defp note(pending) do
    doc = pending.doc |> Enum.reverse() |> Enum.join(" ") |> String.trim()
    %{doc: doc, section: pending.section}
  end

  defp banner?(line), do: String.match?(line, ~r/\A\/\/\s*[-=]{3,}/u)

  defp comment(line), do: String.replace(line, ~r/\A\/\/\s?+/u, "")

  # `MJAPI void mj_step(const mjModel* m, mjData* d);` — the name is the first
  # identifier that opens a parameter list.
  defp declared_name(line) do
    case Regex.run(~r/\b([A-Za-z_][A-Za-z0-9_]*)\s*\(/u, line, capture: :all_but_first) do
      [name] -> name
      _ -> nil
    end
  end

  # `MJAPI <declarator>;` — the declarator may wrap, and its parameter list may
  # contain nested parentheses (`mju_error(const char*, ...) mjPRINTFLIKE(1, 2)`).
  defp declarations(text) do
    text
    |> String.split("MJAPI")
    |> Enum.drop(1)
    |> Enum.map(fn chunk -> chunk |> String.split(";", parts: 2) |> hd() end)
  end

  defp declaration!(chunk) do
    # Pack the declarator onto one line, then take it apart.
    text = chunk |> String.replace(~r/\s+/u, " ") |> String.trim()

    case Regex.run(~r/^(extern\s+)?(.*?)\b([A-Za-z_][A-Za-z0-9_]*)\s*[\(\[]/u, text) do
      # `MJAPI extern void* (*mju_user_malloc)(size_t)` — a global, not a function.
      [_, extern, _rest, _name] when extern != "" ->
        []

      [_, _extern, returns, name] ->
        [declaration(text, String.trim(returns), name)]

      _ ->
        []
    end
  end

  defp declaration(text, returns, name) do
    params = text |> parameter_list(name) |> parameters()

    # `const char*` has to arrive as `{name: "char", const: true, pointers: 1}`,
    # not as a type called `char*`.
    {stars, base} = stars(returns)
    returned = parse_type(base)
    returned = %{returned | pointers: returned.pointers + stars}

    %{
      name: name,
      returns: returned,
      parameters: params,
      doc: "",
      section: nil,
      variadic: Enum.any?(params, &(&1.kind == :opaque and &1.name == "..."))
    }
  end

  defp parameter_list(text, name) do
    case Regex.run(~r/\b#{Regex.escape(name)}\s*\(/u, text, return: :index) do
      [{start, length}] -> inner(text, start + length)
      nil -> ""
    end
  end

  # Balanced scan to the closing parenthesis of the parameter list.
  defp inner(text, offset) do
    {params, _rest} = text |> binary_part(offset, byte_size(text) - offset) |> scan(1, "", [])
    params
  end

  defp scan("", _depth, current, acc), do: {Enum.join(Enum.reverse([current | acc])), ""}
  defp scan(")" <> rest, 1, current, acc), do: {Enum.join(Enum.reverse([current | acc])), rest}

  defp scan(")" <> rest, depth, current, acc),
    do: scan(rest, depth - 1, current <> ")", acc)

  defp scan("(" <> rest, depth, current, acc), do: scan(rest, depth + 1, current <> "(", acc)

  defp scan(<<char::utf8, rest::binary>>, depth, current, acc),
    do: scan(rest, depth, current <> <<char::utf8>>, acc)

  defp parameters(""), do: []
  defp parameters("void"), do: []

  defp parameters(text) do
    text
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parameter/1)
  end

  defp parameter("..."),
    do: %{
      name: "...",
      type: %{name: "void", const: false, pointers: 1},
      array: nil,
      kind: :opaque
    }

  defp parameter(text) do
    {without_array, array} =
      case Regex.run(~r/^(.*?)\s*\[([^\]]*)\]\s*$/u, text) do
        [_, head, dims] -> {head, String.trim(dims)}
        _ -> {text, nil}
      end

    text = String.replace(without_array, ~r/\s+/u, " ") |> String.trim()
    {stars, text} = stars(text)
    {name, text} = name(text)
    type = parse_type(text)
    type = %{type | pointers: type.pointers + stars}

    %{name: name, type: type, array: array, kind: classify(type, array, name)}
  end

  # `mjtNum* x` and `mjtNum *x` both occur.
  defp stars(text) do
    count = length(Regex.scan(~r/\*/u, text))
    {count, String.replace(text, ~r/\*+/u, " ")}
  end

  # The trailing identifier is the parameter's name; a declaration without one
  # (`mjtNum`) is a type and takes the type's own name.
  defp name(text) do
    words = text |> String.split(" ") |> Enum.reject(&(&1 == ""))

    case words do
      [] ->
        {"", text}

      [_single] ->
        {"", text}

      _ ->
        {List.last(words), words |> Enum.drop(-1) |> Enum.join(" ")}
    end
  end

  @doc false
  def parse_type(text) do
    text = String.replace(text, ~r/\s+/u, " ") |> String.trim()
    const = String.starts_with?(text, "const ") or String.contains?(text, " const ")
    name = text |> String.replace("const ", "") |> String.replace(~r/\s+/u, " ") |> String.trim()

    %{name: name, const: const, pointers: 0}
  end

  # What a NIF can do with a parameter, decided from its type alone.
  defp classify(type, array, _name) do
    cond do
      # An array in the parameter list is a buffer, whatever it holds.
      array != nil and type.pointers == 0 -> :buffer
      # `void*` is anything at all, and `mjfXxx` is a callback, which a generated
      # binding cannot honestly invent.
      type.name in ["void" | @callbacks] -> :opaque
      type.pointers > 0 -> classify_pointer(type)
      type.name in @numeric -> :float
      true -> :integer
    end
  end

  defp classify_pointer(%{pointers: 1} = type) do
    cond do
      type.name in ["mjModel", "mjData"] -> :resource
      type.name == "char" and type.const -> :string
      type.name in ["char", "mjtByte", "mjtBool"] -> :buffer
      type.name in @numeric -> :buffer
      type.name in @integers -> :buffer
      true -> :opaque
    end
  end

  defp classify_pointer(_type), do: :opaque

  # ------------------------------------------------------------------ structs

  # Pointer members MuJoCo does not dimension in `mjxmacro.h`, because they are
  # not arrays of anything a caller can name: the arena every other pointer
  # points into. Excluding one by name here, with the reason, is how a genuine
  # drift between the struct and the X-macro list still fails the build.
  @undimensioned %{
    "mjModel" => %{
      "buffer" => "the arena every other pointer points into; the typed pointers name it"
    },
    "mjData" => %{
      "buffer" => "the arena every other pointer points into; the typed pointers name it",
      "arena" => "the stack arena, addressed by pstack; the typed pointers name what it holds"
    }
  }

  @doc """
  The members of one of MuJoCo's structs, with array dimensions from `mjxmacro.h`.

  Value members (`mjtSize nq`) and pointers (`mjtNum* geom_pos`) are both here,
  because a caller reads both. Arrays declared inline (`mjtNum solver_fwdinv[2]`)
  carry their dimension in the declaration; a pointer carries it in the X-macro
  lists, which is where MuJoCo itself gets it for `mjvScene` and the bindings.
  """
  @spec struct_members!(Path.t(), String.t()) :: [member()]
  def struct_members!(dir, struct) do
    header = Path.join(dir, "mujoco/#{struct_header(struct)}.h")
    dims = xmacro_dimensions!(Path.join(dir, "mujoco/mjxmacro.h"), struct)

    members =
      header
      |> File.read!()
      |> struct_body!(struct)
      |> member_lines()
      |> Enum.map(&member/1)

    verify_dimensions!(struct, members, dims)

    Enum.map(members, fn member ->
      dims =
        case Map.get(dims, member.name) do
          nil -> member.array && {member.array, "1"}
          {dim1, dim2} -> {dim1, dim2}
        end

      classify_member(member, dims)
    end)
  end

  @integer_types ~w(mjtSize int size_t uintptr_t mjtBool mjtByte unsigned short long)
  @float_types ~w(mjtNum float double)
  # What a binary of elements can be, keyed by the C type of one element.
  @element_types %{
    "mjtNum" => {:f64, "mjtNum"},
    "double" => {:f64, "double"},
    "float" => {:f32, "float"},
    "int" => {:i32, "int"},
    "mjtBool" => {:u8, "mjtBool"},
    "mjtByte" => {:u8, "mjtByte"}
  }

  @doc "What an array of this element type is, as `{tag, cpp_type}`."
  def element_type(c_type), do: Map.get(@element_types, c_type)

  @doc """
  What a member is, as far as a binding goes.

    * `:integer` and `:float` — one value of the struct, returned as is;
    * `:array` — a binary of elements plus its two extents;
    * `:unsupported` — nothing a caller can name, with the reason why.
  """
  def classify_member(member, dims) do
    cond do
      member.type.pointers > 0 and dims == nil ->
        %{member | kind: :unsupported, dims: nil, reason: unexposed_reason_for(member)}

      member.type.pointers > 0 ->
        %{member | kind: :array, dims: dims, element: element_type(member.type.name)}

      member.array != nil ->
        %{member | kind: :array, dims: dims, element: element_type(member.type.name)}

      member.type.name in @integer_types ->
        %{member | kind: :integer, dims: nil}

      member.type.name in @float_types ->
        %{member | kind: :float, dims: nil}

      true ->
        %{
          member
          | kind: :unsupported,
            dims: nil,
            reason: "a #{member.type.name} by value, whose fields the C API does not expose here"
        }
    end
  end

  defp unexposed_reason_for(_member) do
    "MuJoCo gives this pointer no extent in mjxmacro.h, so there is no array to read"
  end

  defp struct_header("mjModel"), do: "mjmodel"
  defp struct_header("mjData"), do: "mjdata"
  defp struct_header(other), do: raise("no header known for #{other}")

  defp struct_body!(text, struct) do
    case Regex.run(
           ~r/typedef struct #{struct}_? \{(.*?)\n\}\s*#{struct}\s*;/su,
           text,
           capture: :all_but_first
         ) do
      [body] -> body
      _ -> raise "could not find the declaration of #{struct}"
    end
  end

  # Declarations are one per line in MuJoCo's headers, and a doc comment may run
  # over onto the next line. A member ends at its semicolon.
  #
  # MuJoCo's struct is a run of headings and the declarations under them —
  # `// bodies`, then the `body_` pointers; `// computed by
  # mj_fwdPosition/mj_kinematics`, then what that pass writes. The heading is
  # MuJoCo's own word for what the fields below it are, so each declaration is
  # returned with the heading it was found under.
  defp member_lines(body) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&heading_or_declaration/1)
    |> join_continuations(nil, [])
    |> Enum.reverse()
  end

  defp heading_or_declaration("//" <> comment), do: {:heading, heading(comment)}
  defp heading_or_declaration(line), do: {:declaration, line}

  # `// ---- sizes ----` and `// bodies` are the same kind of thing: a title.
  # The rule of dashes is decoration, so it goes, along with the spaces either
  # side of it — `String.trim/2` stops at the first character outside its set,
  # which leaves the dashes behind a leading space.
  defp heading(comment) do
    comment
    |> String.replace(~r/\A[\s\-=]+/u, "")
    |> String.replace(~r/[\s\-=]+\z/u, "")
  end

  defp join_continuations([], _section, acc), do: acc

  defp join_continuations([{:heading, heading} | rest], _section, acc),
    do: join_continuations(rest, heading, acc)

  defp join_continuations([{:declaration, line} | rest], section, acc) do
    if String.contains?(line, ";") do
      join_continuations(rest, section, [{section, line} | acc])
    else
      case rest do
        [{:declaration, next} | tail] ->
          join_continuations([{:declaration, line <> " " <> next} | tail], section, acc)

        _ ->
          join_continuations(rest, section, [{section, line} | acc])
      end
    end
  end

  defp member({section, line}) do
    pattern =
      ~r/^(?<type>[A-Za-z_][A-Za-z0-9_]*)\s*(?<stars>\*+)?\s*(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*(?:\[(?<dims>[^\]]+)\])?\s*;(?:\s*\/\/\s*(?<doc>.*))?$/u

    case Regex.named_captures(pattern, line) do
      nil ->
        raise "could not read the member declaration #{inspect(line)}"

      captures ->
        type = parse_type(captures["type"])
        stars = if captures["stars"] == "", do: 0, else: String.length(captures["stars"])

        %{
          name: captures["name"],
          type: %{type | pointers: type.pointers + stars},
          array: blank_to_nil(captures["dims"]),
          doc: String.trim(captures["doc"] || ""),
          section: section,
          # Filled in by classify_member/2, once the dimensions are known.
          kind: nil,
          dims: nil,
          element: nil,
          reason: nil
        }
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: String.trim(value)

  defp verify_dimensions!(struct, members, dims) do
    pointers =
      members
      |> Enum.filter(&(&1.type.pointers > 0))
      |> Enum.map(& &1.name)

    known = Map.get(@undimensioned, struct, %{})
    missing = Enum.reject(pointers, &(Map.has_key?(dims, &1) or Map.has_key?(known, &1)))

    if missing != [] do
      raise """
      #{struct} has pointer members with no dimension in mjxmacro.h:

        #{Enum.join(missing, ", ")}

      The X-macro list and the struct have drifted apart. Nothing was generated.
      """
    end
  end

  # `X ( mjtNum, geom_pos, ngeom, 3 )` inside any `#define …_POINTERS*` block.
  # MuJoCo splits the list into a block per object kind (`_BODY`, `_JOINT`, …) and
  # composes them; the dimensions are in the parts, so every part is read.
  # `MJ_M(nuser_body)` is MuJoCo's way of saying "this dimension is a member";
  # unwrapping it leaves a name we can read from the struct.
  defp xmacro_dimensions!(path, struct) do
    prefix = if struct == "mjModel", do: "MJMODEL", else: "MJDATA"

    blocks =
      path
      |> File.read!()
      |> then(
        &Regex.scan(
          ~r/#{prefix}[A-Z_]*POINTERS[A-Z_]*\s(.*?)(?=\n#define|\z)/su,
          &1,
          capture: :all_but_first
        )
      )

    if blocks == [], do: raise("mjxmacro.h has no #{prefix} pointer lists")

    blocks
    |> List.flatten()
    |> Enum.join("\n")
    # `mjxmacro.h` says of `MJ_M`: "macro for annotating that an array size in
    # an X macro is a member of mjModel; by default this macro does nothing".
    # So a bare name in a pointer list is a model member, `MJ_M(x)` says so out
    # loud, and `MJ_D(x)` is a member of mjData. Which struct a dimension comes
    # from decides how the accessor spells it, so the marker is kept.
    |> String.replace(~r/MJ_M\(([^)]*)\)/u, "\\1@model")
    |> String.replace(~r/MJ_D\(([^)]*)\)/u, "\\1@data")
    |> then(
      &Regex.scan(
        # `X` and `XNV` are the same entry — `XNV` only marks a field that
        # `mjvScene` does not need, and MuJoCo defines `XNV` as `X` by default.
        ~r/(?:XNV|X)\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,\s*([A-Za-z_][A-Za-z0-9_]*)\s*,\s*([^,]+?)\s*,\s*([^)]+?)\s*\)/u,
        &1
      )
    )
    |> Map.new(fn [_, _type, name, dim1, dim2] ->
      {name, {String.trim(dim1), String.trim(dim2)}}
    end)
  end

  @doc """
  Why a member cannot be read as an array, when it cannot.
  """
  @spec unexposed_reason(String.t(), String.t()) :: String.t() | nil
  def unexposed_reason(struct, member),
    do: Map.get(@undimensioned, struct, %{}) |> Map.get(member)

  # ------------------------------------------------------------------ enums

  @doc """
  Every `typedef enum mjtX { … } mjtX;` in one header.
  """
  @spec enums_in(Path.t()) :: [enum()]
  def enums_in(path) do
    path
    |> File.read!()
    |> strip_comments()
    |> then(
      &Regex.scan(
        ~r/typedef\s+enum\s+([A-Za-z_][A-Za-z0-9_]*)\s*\{(.*?)\}\s*([A-Za-z_][A-Za-z0-9_]*)\s*;/su,
        &1
      )
    )
    |> Enum.map(fn [_, name, body, _alias] -> %{name: name, items: enum_items(body)} end)
  end

  # An item's value is usually a decimal, and sometimes an OR of other items in
  # the same enum (`mjSTATE_PHYSICS = mjSTATE_QPOS | mjSTATE_QVEL | …`). The
  # literals are resolved directly; the ORs are resolved against the names in the
  # same enum, which is enough for every enum MuJoCo declares. What still cannot
  # be resolved is left without a value rather than guessed, and the generated
  # Elixir leaves that name out and says why.
  defp enum_items(body) do
    items =
      body
      |> String.split(",")
      |> Enum.map(&(&1 |> String.replace(~r/\s+/u, " ") |> String.trim()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&enum_item/1)
      |> Enum.reject(&is_nil/1)

    resolve_enum_values(items)
  end

  defp enum_item(text) do
    case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)\s*(?:=\s*(.+))?$/u, text) do
      [_, name] ->
        %{name: name, expression: nil, value: nil, doc: ""}

      [_, name, expression] ->
        %{name: name, expression: String.trim(expression), value: nil, doc: ""}

      nil ->
        raise "could not read the enum item #{inspect(text)}"
    end
  end

  defp resolve_enum_values(items) do
    # C numbers an item without `= value` one past the item before it, so the
    # enumeration is read in order. An expression that cannot be resolved yet
    # stops the numbering rather than inventing a number for what follows.
    {items, known, _next} =
      Enum.reduce(items, {[], %{}, 0}, fn item, {acc, known, next} ->
        value =
          case item.expression do
            nil -> next
            expression -> value_of(expression, known)
          end

        known = if value == nil, do: known, else: Map.put(known, item.name, value)
        {[%{item | value: value} | acc], known, if(value == nil, do: nil, else: value + 1)}
      end)

    # Anything still unresolved may have been declared before the item it names.
    items |> Enum.reverse() |> then(&resolve_remaining(&1, known, 3))
  end

  defp resolve_remaining(items, _known, 0), do: items

  defp resolve_remaining(items, known, passes) do
    next =
      Enum.map(items, fn
        %{value: nil} = item -> %{item | value: value_of(item.expression, known)}
        item -> item
      end)

    if next == items do
      next
    else
      known = for item <- next, item.value != nil, into: %{}, do: {item.name, item.value}
      resolve_remaining(next, known, passes - 1)
    end
  end

  # The values MuJoCo writes are decimals, ORs of siblings
  # (`mjSTATE_PHYSICS = mjSTATE_QPOS | …`) and shifts (`mjSTATE_TIME = 1<<0`).
  # That is the whole grammar these headers use, so it is the whole grammar read
  # here; an expression outside it leaves the item without a value rather than
  # with a guess.
  defp value_of(nil, _known), do: nil

  defp value_of(expression, known) do
    expression
    |> String.split("|")
    |> Enum.map(&String.trim/1)
    |> Enum.reduce_while(0, fn part, acc ->
      case shifted(part, known) do
        nil -> {:halt, nil}
        value -> {:cont, Bitwise.bor(acc, value)}
      end
    end)
  end

  defp shifted(part, known) do
    case String.split(part, "<<", parts: 2) do
      [only] ->
        operand(only, known)

      [left, right] ->
        case {operand(left, known), operand(right, known)} do
          {l, r} when is_integer(l) and is_integer(r) and r >= 0 and r < 64 ->
            Bitwise.bsl(l, r)

          _ ->
            nil
        end
    end
  end

  defp operand(text, known) do
    text = text |> String.trim() |> String.replace(~r/^\((.*)\)$/u, "\\1") |> String.trim()

    case Integer.parse(text) do
      {value, ""} -> value
      _ -> Map.get(known, text)
    end
  end

  defp strip_comments(text) do
    text
    |> String.replace(~r{/\*.*?\*/}su, " ")
    |> String.replace(~r{//[^\n]*}u, "")
  end
end
