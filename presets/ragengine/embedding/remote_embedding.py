# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.
from typing import Any
import requests
import json
from .base import BaseEmbeddingModel
from ragengine.metrics.helpers import record_embedding_metrics

class RemoteEmbeddingModel(BaseEmbeddingModel):
    def __init__(self, model_url: str, api_key: str, /, **data: Any):
        """
        Initialize the RemoteEmbeddingModel.

        Args:
            model_url (str): The URL of the embedding model API endpoint.
            api_key (str): The API key for accessing the API.
        """
        super().__init__(**data)
        self.model_url = model_url
        self.api_key = api_key

    @record_embedding_metrics
    def _get_text_embedding(self, text: str):
        """Returns the text embedding for a given input string."""
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json"
        }
        payload = {
            "inputs": text
        }

        try:
            response = requests.post(self.model_url, headers=headers, data=json.dumps(payload))
            response.raise_for_status()  # Raise an HTTPError for bad responses
            embedding = response.json()  # Assumes the API returns JSON
            if isinstance(embedding, list):
                return embedding
            else:
                raise ValueError("Unexpected response format. Expected a list.")
        except requests.exceptions.RequestException as e:
            raise RuntimeError(f"Failed to get embedding from remote model: {e}")

    def _get_query_embedding(self, query: str):
        return self._get_text_embedding(query)

    def get_embedding_dimension(self) -> int:
        """Infers the embedding dimension by making a remote call to get the embedding of a dummy text."""
        dummy_input = "This is a dummy sentence."
        embedding = self._get_text_embedding(dummy_input)
        
        return len(embedding)
