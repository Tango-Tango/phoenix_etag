defmodule PhoenixETagTest do
  use ExUnit.Case, async: true
  doctest PhoenixETag

  defmodule Schema do
    defstruct [:id, :updated_at]
  end

  defmodule View do
    use Phoenix.View, root: "does-not-matter"

    def stale_checks("show." <> _format, %{data: data}) do
      [etag: PhoenixETag.schema_etag(data), last_modified: PhoenixETag.schema_last_modified(data)]
    end

    def stale_checks("show." <> _format, %{checks: checks}), do: checks

    def render("show.json", %{data: data}) do
      %{id: data.id}
    end

    def render("show.html", %{data: %{id: id}}) do
      "Template for id: #{id}"
    end

    def render("show.html", %{data: d}) do
      "Template for: #{inspect(d)}"
    end

    def render("inner.html", %{conn: conn}) do
      mod = Phoenix.Controller.view_module(conn)
      tmpl = Phoenix.Controller.view_template(conn)
      "View module is #{mod} and view template is #{tmpl}."
    end

    def render("show." <> _format, %{checks: checks}) do
      "Template for checks: #{inspect(checks)}"
    end
  end

  defmodule Layout do
    use Phoenix.View, root: "does-not-matter"

    def render("app.html", %{data: data} = assigns) do
      "Layout for id: #{data.id}\n" <>
        render(
          Phoenix.Controller.view_module(assigns.conn),
          Phoenix.Controller.view_template(assigns.conn),
          assigns
        )
    end
  end

  import Phoenix.ConnTest, except: [conn: 0]
  import Plug.Conn
  import Phoenix.Controller
  import PhoenixETag

  @naive ~N[2017-02-16 16:28:05.967734]
  @date DateTime.from_naive!(@naive, "Etc/UTC")
  @etag "W/ 34d2cbd4b03b46274fd784fb792a57f4"
  @etag_empty_list "W/ a52eab6056871e78f2296dc6d1f4aaaf"
  @last_modified "Thu, 16 Feb 2017 16:28:05 GMT"

  describe "schema_etag/1" do
    test "with empty result" do
      assert schema_etag(nil) == nil
      assert schema_etag([]) == @etag_empty_list
    end

    test "with a single resource" do
      schema = %Schema{id: 1, updated_at: @date}
      assert schema_etag(schema) == @etag
    end

    test "with multiple resources" do
      schema = [%Schema{id: 1, updated_at: @naive}]
      assert schema_etag(schema) == @etag
    end
  end

  describe "schema_last_modified/1" do
    test "with empty result" do
      assert schema_last_modified(nil) == nil
      assert schema_last_modified([]) == nil
    end

    test "with a single resource" do
      schema = %Schema{updated_at: @date}
      assert schema_last_modified(schema) == @date
    end

    test "with multiple resources" do
      now = DateTime.utc_now()
      schema = [%Schema{updated_at: @naive}, %Schema{updated_at: now}]
      assert schema_last_modified(schema) == now
    end
  end

  describe "render_if_stale" do
    test "responds with etag" do
      conn = render_if_stale(conn(), "show.html", checks: [etag: @etag])
      assert get_resp_header(conn, "etag") == [@etag]
      assert get_resp_header(conn, "last-modified") == []
      assert conn.status == 200
    end

    test "responds with last-modified" do
      conn = render_if_stale(conn(), "show.html", checks: [last_modified: @date])
      assert get_resp_header(conn, "last-modified") == [@last_modified]
      assert get_resp_header(conn, "etag") == []
      assert conn.status == 200
    end

    test "responds with both" do
      conn = render_if_stale(conn(), "show.html", checks: [last_modified: @date, etag: @etag])
      assert get_resp_header(conn, "last-modified") == [@last_modified]
      assert get_resp_header(conn, "etag") == [@etag]
      assert conn.status == 200
    end

    test "responds with neither" do
      testcases = [
        [],
        [last_modified: nil, etag: nil]
      ]

      for checks <- testcases do
        conn = render_if_stale(conn(), "show.html", checks: checks)
        assert get_resp_header(conn, "last-modified") == []
        assert get_resp_header(conn, "etag") == []
        assert conn.status == 200
      end
    end

    test "responds with 304 for fresh content based on etag" do
      testcases = [
        {[], 200},
        {[etag: nil], 200},
        {[etag: "W/ etag2"], 200},
        {[etag: "W/ etag2", last_modified: @date], 200},
        {[etag: nil, last_modified: @date], 200},
        {[etag: "W/ etag1"], 304},
        {[etag: "W/ etag1", last_modified: nil], 304},
        {[etag: "W/ etag1", last_modified: @date], 304}
      ]

      for {checks, expected_status} <- testcases do
        conn = put_req_header(conn(), "if-none-match", "W/ etag1")
        conn = render_if_stale(conn, "show.html", checks: checks)
        assert conn.status == expected_status
        assert conn.state == :sent
      end
    end

    test "responds with 304 for fresh content based on last_modified" do
      testcases = [
        {@date, 304},
        {@naive, 304},
        {DateTime.add(@date, -1, :second), 304},
        {DateTime.add(@date, 1, :second), 200},
        {nil, 200}
      ]

      for {date, expected_status} <- testcases do
        conn = put_req_header(conn(), "if-modified-since", @last_modified)
        conn = render_if_stale(conn, "show.html", checks: [last_modified: date])
        assert conn.status == expected_status
        assert conn.state == :sent
      end
    end

    test "if-none-match takes precence if both headers are present" do
      testcases = [
        {@date, @etag, 304},
        {@date, "other-etag", 304},
        {DateTime.add(@date, 1, :second), @etag, 304},
        {DateTime.add(@date, -1, :second), @etag, 304}
      ]

      for {date, etag, expected_status} <- testcases do
        conn = put_req_header(conn(), "if-modified-since", @last_modified)
        conn = put_req_header(conn, "if-none-match", @etag)
        conn = render_if_stale(conn, "show.html", checks: [last_modified: date, etag: etag])
        assert conn.status == expected_status
        assert conn.state == :sent
      end
    end

    test "only GET and HEAD return 304" do
      testcases = [
        {"GET", 304},
        {"HEAD", 304},
        {"POST", 200},
        {"PUT", 200},
        {"PATCH", 200},
        {"DELETE", 200}
      ]

      for {method, expected_status} <- testcases do
        conn = put_req_header(conn(), "if-none-match", @etag)
        conn = %{conn | method: method}
        conn = render_if_stale(conn, "show.html", checks: [etag: @etag])
        assert conn.status == expected_status
      end
    end
  end

  describe "phoenix render" do
    # A lot of this is borrowed from:
    # https://github.com/phoenixframework/phoenix/blob/d07233067d4af8eeb7b72f3f296a2a9ade70be40/test/phoenix/controller/render_test.exs

    defp conn() do
      build_conn(:get, "/") |> put_view(View) |> fetch_query_params
    end

    defp layout_conn() do
      build_conn() |> put_layout({Layout, :app}) |> put_view(View)
    end

    defp html_response?(conn) do
      assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    end

    defp schema() do
      %Schema{id: 1, updated_at: @naive}
    end

    test "renders string template" do
      conn = render_if_stale(conn(), "show.html", data: schema())
      assert conn.resp_body =~ "id: 1"
      assert html_response?(conn)
      refute conn.halted
      assert view_template(conn) == "show.html"
    end

    test "renders atom template" do
      conn = put_format(conn(), "html")
      conn = render_if_stale(conn, :show, data: schema())
      assert conn.resp_body =~ "id: 1"
      assert html_response?(conn)
      refute conn.halted
      assert view_template(conn) == "show.html"
    end

    test "renders string template with put layout" do
      conn = render_if_stale(layout_conn(), "show.html", data: schema())
      assert conn.resp_body =~ "id: 1"
      assert html_response?(conn)
    end

    test "renders atom template with put layout" do
      conn = put_format(layout_conn(), "html")
      conn = render_if_stale(conn, :show, data: schema())
      assert conn.resp_body =~ "id: 1"
      assert html_response?(conn)
    end

    test "renders template with overriding layout option" do
      conn = render_if_stale(layout_conn(), "show.html", data: schema(), layout: false)
      assert conn.resp_body =~ "Template"
      assert html_response?(conn)
    end

    test "renders template with atom layout option" do
      conn = render_if_stale(conn(), "show.html", data: schema(), layout: {Layout, :app})
      assert conn.resp_body =~ "Layout"
      assert html_response?(conn)
    end

    test "renders template with string layout option" do
      conn = render_if_stale(conn(), "show.html", data: schema(), layout: {Layout, "app.html"})
      assert conn.resp_body =~ "Layout"
      assert html_response?(conn)
    end

    test "render with layout sets view_module/template for layout and inner view" do
      conn = render(conn(), "inner.html", data: schema(), layout: {Layout, :app})

      assert conn.resp_body ==
               "Layout for id: 1\nView module is Elixir.PhoenixETagTest.View and view template is inner.html."
    end

    test "render without layout sets inner view_module/template assigns" do
      conn = render(conn(), "inner.html", [])

      assert conn.resp_body ==
               "View module is Elixir.PhoenixETagTest.View and view template is inner.html."
    end

    test "renders with conn status code" do
      conn = %Plug.Conn{conn() | status: 404}
      conn = render_if_stale(conn, "show.html", data: schema())
      assert conn.status == 404
    end

    test "skips layout depending on layout_formats with string template" do
      conn = layout_conn() |> put_layout([]) |> render_if_stale("show.html", data: schema())

      assert conn.resp_body =~ "Template"
      assert html_response?(conn)

      conn = render_if_stale(layout_conn(), "show.json", data: schema())
      assert conn.resp_body == ~s({"id":1})
    end

    test "skips layout depending on layout_formats with atom template" do
      conn = put_format(layout_conn(), "html")
      conn = conn |> put_layout([]) |> render_if_stale(:show, data: schema())
      assert conn.resp_body =~ "Template"
      assert html_response?(conn)

      conn = put_format(layout_conn(), "json")
      conn = render_if_stale(conn, :show, data: schema())
      assert conn.resp_body == ~s({"id":1})
    end

    test "merges render assigns" do
      conn = render_if_stale(conn(), "show.html", data: schema())
      assert conn.resp_body =~ "id: 1"
      assert conn.assigns.data == schema()
    end

    test "uses connection assigns" do
      conn = conn() |> assign(:data, schema()) |> render_if_stale("show.html")
      assert conn.resp_body =~ "id: 1"
      assert html_response?(conn)
    end

    test "uses custom status" do
      conn = render_if_stale(conn(), "show.html", data: schema())
      assert conn.status == 200

      conn = render_if_stale(put_status(conn(), :created), "show.html", data: schema())
      assert conn.status == 201
    end

    test "uses action name" do
      conn = put_format(conn(), "html")
      conn = put_in(conn.private[:phoenix_action], :show)
      conn = render(conn, data: schema())
      assert conn.resp_body =~ "id: 1"
    end

    test "render/3 renders with View and Template with atom for template" do
      conn = put_format(conn(), "json")
      conn = put_in(conn.private[:phoenix_action], :show)
      conn = put_view(conn, nil)
      conn = assign(conn, :data, schema())
      conn = render_if_stale(conn, View, :show)
      assert conn.resp_body == ~s({"id":1})
    end

    test "render/3 renders with View and Template" do
      conn = put_format(conn(), "json")
      conn = put_in(conn.private[:phoenix_action], :show)
      conn = put_view(conn, nil)
      conn = assign(conn, :data, schema())
      conn = render_if_stale(conn, View, "show.json")
      assert conn.resp_body == ~s({"id":1})
    end

    test "render/4 renders with View and Template" do
      conn = put_format(conn(), "html")
      conn = put_in(conn.private[:phoenix_action], :show)
      conn = put_view(conn, nil)
      conn = render_if_stale(conn, View, "show.html", data: schema())
      assert conn.resp_body =~ "id: 1"
    end

    test "errors when rendering without format" do
      assert_raise RuntimeError, ~r/cannot render template :show because conn.params/, fn ->
        render_if_stale(conn(), :show)
      end

      assert_raise RuntimeError, ~r/cannot render template "show" without format/, fn ->
        render_if_stale(conn(), "show")
      end
    end

    test "errors when rendering without view" do
      assert_raise RuntimeError, ~r/no view was found/, fn ->
        render_if_stale(conn() |> put_view(nil), "show.html")
      end
    end
  end
end
