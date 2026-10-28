defmodule Exmaster.Paid do
  @moduledoc """
  Sending a list over TCP within the reply budget (`Exmaster.RateLimit`),
  however long it is: in chunks of 64 KB at most, each paid for before it
  is sent, waiting for the budget when it is spent. A list larger than
  the budget's burst still goes out, at its rate.

  The connection's end moves by the time waited, up to a minute of it in
  all, so a client that reads slowly has its own time and no more. One
  that stops reading is closed by the socket's send timeout. UT2004's and
  GameSpy server browsing's lists go out this way.
  """
  alias Exmaster.RateLimit

  @chunk 65_536
  @max_wait 60_000

  @doc "Parts (iodata each) in chunks of at most 64 KB, or one part, with their sizes."
  def chunks(parts) do
    Enum.chunk_while(
      parts,
      {[], 0},
      fn part, {acc, size} ->
        n = IO.iodata_length(part)

        if acc != [] and size + n > @chunk,
          do: {:cont, {Enum.reverse(acc), size}, {[part], n}},
          else: {:cont, {[part | acc], size + n}}
      end,
      fn
        {[], _} -> {:cont, {[], 0}}
        {acc, size} -> {:cont, {Enum.reverse(acc), size}, {[], 0}}
      end
    )
  end

  @doc """
  Sends each chunk once the budget has paid for it, while the connection
  hasn't ended: `:ok` or `:error`. chunks may be a stream, so a chunk is
  only made, encrypted say, as it is sent. credit is what the reservation
  (`RateLimit.reserve_reply/1`) has paid for already, ends when the
  connection ends, waited how long it has waited so far.
  """
  def send(sock, chunks, credit, ends, waited \\ 0) do
    Enum.reduce_while(chunks, {credit, waited}, fn {chunk, size}, {credit, waited} ->
      with {:ok, waited} <- pay(max(size - credit, 0), waited),
           true <- Exmaster.now() < ends + waited,
           :ok <- :gen_tcp.send(sock, chunk) do
        {:cont, {max(credit - size, 0), waited}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      _ -> :ok
    end
  end

  defp pay(0, waited), do: {:ok, waited}

  defp pay(bytes, waited) do
    case RateLimit.spend_reply(bytes, Exmaster.now()) do
      :ok ->
        {:ok, waited}

      {:error, wait} when waited + wait <= @max_wait ->
        Process.sleep(wait)
        pay(bytes, waited + wait)

      {:error, _} ->
        :error
    end
  end
end
