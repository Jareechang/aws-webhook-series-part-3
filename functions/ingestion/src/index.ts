
import {
  APIGatewayProxyEvent,
  APIGatewayProxyResult
} from 'aws-sdk';

// Default starter
export const handler = async(
  event: APIGatewayProxyEvent
): Promise<APIGatewayProxyResult> => {
  console.log('Event : ', JSON.stringify({
    event,
  }, null, 4));
  let responseMessage = 'default message from ingestion';
  return {
    statusCode: 200,
    body: JSON.stringify({
      message: responseMessage,
    }),
  }
}
