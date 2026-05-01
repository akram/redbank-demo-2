"""Local RAG ingestion — load RedBank PDFs from disk into PGVector.

Usage:
    python ingest_local.py                          # defaults: localhost:5432, db=db, user=app
    python ingest_local.py --pg-host 127.0.0.1 --pg-port 15432
    PG_HOST=myhost PG_PORT=5433 python ingest_local.py

Reads PDFs from ../docs/{admin,user}/ relative to this script.
"""

import argparse
import os
import sys
from pathlib import Path

from langchain_community.document_loaders import PyPDFLoader
from langchain_huggingface import HuggingFaceEmbeddings
from langchain_postgres import PGEngine, PGVectorStore
from langchain_text_splitters import RecursiveCharacterTextSplitter
from urllib.parse import quote


DOCS_DIR = Path(__file__).resolve().parent.parent / "docs"

COLLECTIONS = {
    "admin": DOCS_DIR / "admin",
    "user": DOCS_DIR / "user",
}


def ingest_collection(
    collection_name: str,
    docs_path: Path,
    connection_string: str,
    chunk_size: int,
    chunk_overlap: int,
) -> int:
    """Load all PDFs from docs_path, chunk, embed, and store in PGVector."""
    pdf_files = sorted(docs_path.glob("*.pdf"))
    if not pdf_files:
        print(f"  No PDFs found in {docs_path}", file=sys.stderr)
        return 0

    # Load pages from all PDFs
    all_docs = []
    for pdf in pdf_files:
        print(f"  Loading {pdf.name}")
        loader = PyPDFLoader(str(pdf))
        all_docs.extend(loader.load())

    # Chunk
    splitter = RecursiveCharacterTextSplitter(
        chunk_size=chunk_size,
        chunk_overlap=chunk_overlap,
    )
    chunks = splitter.split_documents(all_docs)
    for chunk in chunks:
        chunk.metadata["collection"] = collection_name

    # Embed + store
    embeddings = HuggingFaceEmbeddings(model_name="nomic-ai/nomic-embed-text-v1.5")
    engine = PGEngine.from_connection_string(url=connection_string)
    store = PGVectorStore.create_sync(
        engine=engine,
        table_name="embeddings",
        embedding_service=embeddings,
        metadata_columns=["collection"],
    )
    store.add_documents(chunks)
    return len(chunks)


def main():
    parser = argparse.ArgumentParser(description="Local RAG ingestion into PGVector")
    parser.add_argument("--pg-host", default=os.getenv("PG_HOST", "localhost"))
    parser.add_argument("--pg-port", default=os.getenv("PG_PORT", "5432"))
    parser.add_argument("--pg-database", default=os.getenv("PG_DATABASE", "db"))
    parser.add_argument("--pg-user", default=os.getenv("PG_USER", "app"))
    parser.add_argument("--pg-password", default=os.getenv("PG_PASSWORD", "app"))
    parser.add_argument("--chunk-size", type=int, default=1000)
    parser.add_argument("--chunk-overlap", type=int, default=200)
    parser.add_argument(
        "--collections",
        nargs="+",
        choices=list(COLLECTIONS.keys()),
        default=list(COLLECTIONS.keys()),
        help="Which collections to ingest (default: all)",
    )
    args = parser.parse_args()

    connection_string = (
        f"postgresql+psycopg://{args.pg_user}:{args.pg_password}"
        f"@{args.pg_host}:{args.pg_port}/{args.pg_database}"
        f"?options={quote('-c app.current_role=admin')}"
    )

    total = 0
    for name in args.collections:
        docs_path = COLLECTIONS[name]
        print(f"Ingesting '{name}' collection from {docs_path}")
        count = ingest_collection(
            collection_name=name,
            docs_path=docs_path,
            connection_string=connection_string,
            chunk_size=args.chunk_size,
            chunk_overlap=args.chunk_overlap,
        )
        print(f"  -> {count} chunks stored")
        total += count

    print(f"\nDone. {total} total chunks ingested.")


if __name__ == "__main__":
    main()
